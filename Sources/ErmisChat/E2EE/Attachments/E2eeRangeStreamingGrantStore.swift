//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeRangeStreamingGrantStoreError: Error, Equatable {
    case mismatchedAsset
    case expiredGrant
}

enum E2eeRangeStreamingGrantStoreEvent: Sendable {
    case initialRequest
    case renewalRequest
}

/// Asset-session grant cache with one real renewal flight and one proactive timer per asset.
actor E2eeRangeStreamingGrantStore {
    typealias GrantProvider = @Sendable (String) async throws -> E2eeRangeStreamingGrant
    typealias FallbackHandler = @Sendable (String) async -> Void
    typealias EventHandler = @Sendable (E2eeRangeStreamingGrantStoreEvent) -> Void

    private struct RenewalFlight {
        let id: UUID
        let task: Task<E2eeRangeStreamingGrant, Error>
    }

    private struct Session {
        var grant: E2eeRangeStreamingGrant?
        var renewalFlight: RenewalFlight?
        var proactiveRenewalTask: Task<Void, Never>?
        var proactiveGeneration: UUID?
    }

    private var sessions: [String: Session] = [:]
    private let grantProvider: GrantProvider
    private let clock: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private let eventHandler: EventHandler

    init(
        grantProvider: @escaping GrantProvider,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { target in
            let interval = target.timeIntervalSinceNow
            if interval > 0 {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        },
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        self.grantProvider = grantProvider
        self.clock = clock
        self.sleepUntil = sleepUntil
        self.eventHandler = eventHandler
    }

    func grant(for assetId: String) async throws -> E2eeRangeStreamingGrant {
        try await grant(for: assetId, forceRefresh: false)
    }

    private func grant(
        for assetId: String,
        forceRefresh: Bool
    ) async throws -> E2eeRangeStreamingGrant {
        var session = sessions[assetId] ?? Session()
        if !forceRefresh,
           let existing = session.grant,
           !existing.isExpired(now: clock()) {
            return existing
        }

        let flight: RenewalFlight
        if let existing = session.renewalFlight {
            flight = existing
        } else {
            let isRenewal = forceRefresh || session.grant != nil
            let provider = grantProvider
            let flightId = UUID()
            flight = RenewalFlight(
                id: flightId,
                task: Task { try await provider(assetId) }
            )
            session.renewalFlight = flight
            sessions[assetId] = session
            eventHandler(isRenewal ? .renewalRequest : .initialRequest)
        }

        do {
            let fresh = try await flight.task.value
            guard fresh.assetId == assetId else {
                throw E2eeRangeStreamingGrantStoreError.mismatchedAsset
            }
            guard !fresh.isExpired(now: clock(), slack: 0) else {
                throw E2eeRangeStreamingGrantStoreError.expiredGrant
            }

            if sessions[assetId]?.renewalFlight?.id == flight.id {
                sessions[assetId]?.grant = fresh
                sessions[assetId]?.renewalFlight = nil
                scheduleProactiveRenewal(for: assetId, grant: fresh)
            }
            return fresh
        } catch {
            if sessions[assetId]?.renewalFlight?.id == flight.id {
                sessions[assetId]?.renewalFlight = nil
            }
            throw error
        }
    }

    /// A request may replace its credential only once after an authorization failure. Concurrent
    /// failures still join the same renewal flight.
    func handleUnauthorized(
        assetId: String,
        httpStatus: Int,
        grantAttempt: Int,
        failedGrantURL: URL? = nil,
        fallback: FallbackHandler
    ) async -> E2eeRangeStreamingGrant? {
        guard httpStatus == 401 || httpStatus == 403 else { return nil }
        guard grantAttempt == 0 else {
            await fallback(assetId)
            return nil
        }

        if let failedGrantURL,
           let current = sessions[assetId]?.grant,
           current.grantURL != failedGrantURL,
           !current.isExpired(now: clock()) {
            return current
        }

        sessions[assetId]?.grant = nil
        sessions[assetId]?.proactiveRenewalTask?.cancel()
        sessions[assetId]?.proactiveRenewalTask = nil
        sessions[assetId]?.proactiveGeneration = nil
        do {
            return try await grant(for: assetId, forceRefresh: true)
        } catch {
            await fallback(assetId)
            return nil
        }
    }

    func invalidateSession(for assetId: String) {
        let session = sessions.removeValue(forKey: assetId)
        session?.renewalFlight?.task.cancel()
        session?.proactiveRenewalTask?.cancel()
    }

    func invalidateAll() {
        let existing = sessions.values
        sessions.removeAll()
        for session in existing {
            session.renewalFlight?.task.cancel()
            session.proactiveRenewalTask?.cancel()
        }
    }

    private func scheduleProactiveRenewal(
        for assetId: String,
        grant: E2eeRangeStreamingGrant
    ) {
        sessions[assetId]?.proactiveRenewalTask?.cancel()
        let generation = UUID()
        sessions[assetId]?.proactiveGeneration = generation
        let deadline = grant.renewalDeadline()
        let sleep = sleepUntil

        sessions[assetId]?.proactiveRenewalTask = Task { [weak self] in
            do {
                try await sleep(deadline)
                try Task.checkCancellation()
                await self?.runProactiveRenewal(
                    for: assetId,
                    generation: generation
                )
            } catch {
                // Session invalidation and timer replacement intentionally cancel this task.
            }
        }
    }

    private func runProactiveRenewal(for assetId: String, generation: UUID) async {
        guard sessions[assetId]?.proactiveGeneration == generation else { return }
        do {
            _ = try await grant(for: assetId, forceRefresh: true)
        } catch {
            // Keep the current grant until it expires; the next range request can retry or fall
            // back to the verified full-download lane.
        }
    }
}

extension E2eeRangeStreamingGrantStore {
    /// Runs a range request, performs at most one credential renewal on 401/403, then invokes the
    /// verified full-download fallback. Cancellation belongs to the player and does not trigger a
    /// potentially expensive fallback after dismissal.
    func executeRangeRequest(
        assetId: String,
        requestBlock: @Sendable (URL) async throws -> Int,
        fallback: FallbackHandler
    ) async {
        guard E2eeRangeStreamingFeatureFlag.isEnabled else {
            await fallback(assetId)
            return
        }

        do {
            let current = try await grant(for: assetId)
            let status = try await requestBlock(current.grantURL)
            guard status == 401 || status == 403 else {
                if !(200...299).contains(status) { await fallback(assetId) }
                return
            }

            guard let renewed = await handleUnauthorized(
                assetId: assetId,
                httpStatus: status,
                grantAttempt: 0,
                failedGrantURL: current.grantURL,
                fallback: fallback
            ) else { return }

            let retryStatus = try await requestBlock(renewed.grantURL)
            if retryStatus == 401 || retryStatus == 403 {
                _ = await handleUnauthorized(
                    assetId: assetId,
                    httpStatus: retryStatus,
                    grantAttempt: 1,
                    failedGrantURL: renewed.grantURL,
                    fallback: fallback
                )
            } else if !(200...299).contains(retryStatus) {
                await fallback(assetId)
            }
        } catch is CancellationError {
            return
        } catch {
            await fallback(assetId)
        }
    }
}
