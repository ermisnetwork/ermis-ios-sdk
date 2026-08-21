//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Process-wide rollback switch for E2EE video range playback.
///
/// Range playback is enabled when the environment override is absent. Existing development and
/// deployment configurations that explicitly set `ERMIS_E2EE_RANGE_STREAMING_ENABLED=1` remain
/// enabled, while any other explicit value disables the lane. Hosts can also disable range
/// playback per client through `ErmisClientConfig.isE2eeRangeStreamingEnabled`.
enum E2eeRangeStreamingFeatureFlag {
    static let environmentKey = "ERMIS_E2EE_RANGE_STREAMING_ENABLED"

    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        guard let override = environment[environmentKey] else { return true }
        return override == "1"
    }
}

#if DEBUG
/// Development-only grant-expiry compression used to exercise proactive renewal on a physical
/// device without waiting for the server-issued TTL. It can only shorten a valid server expiry;
/// release builds do not compile this environment override.
enum E2eeRangeStreamingDebugGrantExpiry {
    static let environmentKey = "ERMIS_E2EE_RANGE_DEBUG_GRANT_TTL_SECONDS"
    static let allowedSeconds: ClosedRange<TimeInterval> = 10...120

    static func resolve(
        serverExpiresAt: Date,
        issuedAt: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (expiresAt: Date, wasShortened: Bool) {
        guard let rawValue = environment[environmentKey],
              let seconds = TimeInterval(rawValue),
              seconds.isFinite,
              allowedSeconds.contains(seconds) else {
            return (serverExpiresAt, false)
        }
        let compressedExpiry = issuedAt.addingTimeInterval(seconds)
        guard compressedExpiry < serverExpiresAt else {
            return (serverExpiresAt, false)
        }
        return (compressedExpiry, true)
    }
}

/// Process-scoped one-shot authorization rejection for physical Debug validation. The injected
/// status is consumed atomically across both Range URLSessions and only replaces an otherwise
/// successful 206 response. Release builds contain neither this type nor its environment key.
final class E2eeRangeStreamingDebugAuthorizationFault: @unchecked Sendable {
    static let environmentKey = "ERMIS_E2EE_RANGE_DEBUG_UNAUTHORIZED_ONCE"
    static let shared = E2eeRangeStreamingDebugAuthorizationFault()

    private let lock = NSLock()
    private var pendingStatus: Int?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        switch environment[Self.environmentKey] {
        case "401": pendingStatus = 401
        case "403": pendingStatus = 403
        default: pendingStatus = nil
        }
    }

    func consumeIfEligible(actualStatus: Int) -> Int? {
        guard actualStatus == 206 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        defer { pendingStatus = nil }
        return pendingStatus
    }
}

/// Process-scoped latched response-contract failure for physical Debug validation. The first
/// otherwise-successful 206 activates the latch atomically across both Range URLSessions. Every
/// later loading request then follows the shared full-original fallback until process exit, so a
/// cancelled AVFoundation probe cannot accidentally consume the test fault and leave playback on
/// the Range lane. Release builds contain neither this type nor its environment key.
final class E2eeRangeStreamingDebugResponseContractFault: @unchecked Sendable {
    struct Decision: Equatable {
        let shouldReject: Bool
        let didActivate: Bool
    }

    static let environmentKey = "ERMIS_E2EE_RANGE_DEBUG_RESPONSE_CONTRACT_ONCE"
    static let shared = E2eeRangeStreamingDebugResponseContractFault()

    private let lock = NSLock()
    private let isEnabled: Bool
    private var hasActivated = false
    private var hasReportedConfiguration = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isEnabled = environment[Self.environmentKey] == "1"
    }

    var isActive: Bool {
        lock.withLock { hasActivated }
    }

    /// Returns the process configuration exactly once so physical-device fault validation can
    /// prove that the launch override reached the app before interpreting playback behavior.
    func consumeConfigurationForLogging() -> Bool? {
        lock.withLock {
            guard !hasReportedConfiguration else { return nil }
            hasReportedConfiguration = true
            return isEnabled
        }
    }

    func decision(actualStatus: Int) -> Decision {
        guard isEnabled, actualStatus == 206 else {
            return Decision(shouldReject: false, didActivate: false)
        }
        return lock.withLock {
            let didActivate = !hasActivated
            hasActivated = true
            return Decision(shouldReject: true, didActivate: didActivate)
        }
    }
}
#endif

/// Central playback selector. File size and duration are intentionally absent: every opaque E2EE
/// video follows the same range policy, while non-video download/export paths stay unchanged.
enum E2eeVideoPlaybackPolicy {
    static func usesRangeStreaming(
        isOpaqueE2eeVideo: Bool,
        clientEnabled: Bool,
        processEnabled: Bool
    ) -> Bool {
        isOpaqueE2eeVideo && clientEnabled && processEnabled
    }
}

/// A Bellboy-issued, asset-scoped credential for ciphertext byte-range requests.
struct E2eeRangeStreamingGrant: Equatable, Sendable {
    let assetId: String
    let grantURL: URL
    /// Absolute expiry returned by Bellboy. The client never invents a TTL.
    let expiresAt: Date
    let issuedAt: Date

    init(assetId: String, grantURL: URL, expiresAt: Date, issuedAt: Date = Date()) {
        self.assetId = assetId
        self.grantURL = grantURL
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
    }

    func ttl(now: Date = Date()) -> TimeInterval {
        expiresAt.timeIntervalSince(now)
    }

    /// Renews early enough to avoid a seek landing on an expiring URL, while never consuming more
    /// than half of a short-lived grant's lifetime.
    static func renewalLead(for ttl: TimeInterval) -> TimeInterval {
        guard ttl > 0 else { return 0 }
        return min(ttl / 2, max(30, min(60, ttl * 0.20)))
    }

    func renewalDeadline() -> Date {
        let originalTTL = max(0, expiresAt.timeIntervalSince(issuedAt))
        return expiresAt.addingTimeInterval(-Self.renewalLead(for: originalTTL))
    }

    func isExpired(now: Date = Date(), slack: TimeInterval = 5) -> Bool {
        ttl(now: now) <= slack
    }
}
