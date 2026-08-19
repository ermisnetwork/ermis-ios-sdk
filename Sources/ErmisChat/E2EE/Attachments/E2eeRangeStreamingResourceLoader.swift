//
// Copyright 2026 Ermis Inc.
//

import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

public final class E2eeAttachmentPlaybackLease: @unchecked Sendable {
    public let asset: AVAsset

    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    init(asset: AVAsset, releaseHandler: @escaping @Sendable () -> Void) {
        self.asset = asset
        self.releaseHandler = releaseHandler
    }

    public func release() {
        lock.lock()
        let handler = releaseHandler
        releaseHandler = nil
        lock.unlock()
        handler?()
    }

    deinit { release() }
}

enum E2eeRangeStreamingResourceError: Error, Equatable {
    case invalidManifest
    case invalidRange
    case invalidResponse
    case invalidContentRange
    case invalidFrame
}

enum E2eeRangeStreamingFallbackReason: String, Sendable {
    case transport
    case responseContract
    case frameIntegrity
    case unknown
}

/// Lock-backed because grant, URLSession and AVFoundation callbacks arrive on different executors.
/// The snapshot and log line intentionally contain counters and fixed categories only.
final class E2eeRangeStreamingTelemetry: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var initialGrantRequests = 0
        var grantRenewalRequests = 0
        var rangeRequests = 0
        var ciphertextBytes = 0
        var cacheHitBytes = 0
        var completedLoadingRequests = 0
        var startupLatencyMilliseconds = 0
        var maximumSeekLatencyMilliseconds = 0
        var fallbackCount = 0
        var lastFallbackReason: E2eeRangeStreamingFallbackReason?
    }

    private let lock = NSLock()
    private var value = Snapshot()

    func recordGrantEvent(_ event: E2eeRangeStreamingGrantStoreEvent) {
        lock.withLock {
            switch event {
            case .initialRequest:
                value.initialGrantRequests += 1
            case .renewalRequest:
                value.grantRenewalRequests += 1
            }
        }
    }

    func recordRangeRequest() {
        lock.withLock {
            value.rangeRequests += 1
        }
    }

    func recordCiphertextBytes(_ ciphertextBytes: Int) {
        lock.withLock {
            value.ciphertextBytes += max(0, ciphertextBytes)
        }
    }

    func recordCacheHit(bytes: Int) {
        lock.withLock {
            value.cacheHitBytes += max(0, bytes)
        }
    }

    func recordLoadingRequest(latency: TimeInterval) {
        let milliseconds = max(0, Int((latency * 1_000).rounded()))
        lock.withLock {
            if value.completedLoadingRequests == 0 {
                value.startupLatencyMilliseconds = milliseconds
            } else {
                value.maximumSeekLatencyMilliseconds = max(
                    value.maximumSeekLatencyMilliseconds,
                    milliseconds
                )
            }
            value.completedLoadingRequests += 1
        }
    }

    func recordFallback(_ reason: E2eeRangeStreamingFallbackReason) {
        lock.withLock {
            value.fallbackCount += 1
            value.lastFallbackReason = reason
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { value }
    }

    static func summary(_ snapshot: Snapshot) -> String {
        let fallback = snapshot.lastFallbackReason?.rawValue ?? "none"
        return "[E2EE_RANGE_PLAYBACK] state=closed initial_grants=\(snapshot.initialGrantRequests) "
            + "renewals=\(snapshot.grantRenewalRequests) range_requests=\(snapshot.rangeRequests) "
            + "ciphertext_bytes=\(snapshot.ciphertextBytes) cache_hit_bytes=\(snapshot.cacheHitBytes) "
            + "completed_requests=\(snapshot.completedLoadingRequests) "
            + "startup_ms=\(snapshot.startupLatencyMilliseconds) "
            + "max_seek_ms=\(snapshot.maximumSeekLatencyMilliseconds) "
            + "fallbacks=\(snapshot.fallbackCount) fallback_reason=\(fallback)"
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

actor E2eeRangeCiphertextReader {
    let grantStore: E2eeRangeStreamingGrantStore
    private let session: URLSession
    private let telemetry: E2eeRangeStreamingTelemetry

    init(
        grantStore: E2eeRangeStreamingGrantStore,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        telemetry: E2eeRangeStreamingTelemetry = .init()
    ) {
        self.grantStore = grantStore
        self.telemetry = telemetry
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        session = URLSession(configuration: sessionConfiguration)
    }

    func read(
        assetId: String,
        range: Range<UInt64>,
        totalCiphertextSize: UInt64
    ) async throws -> Data {
        guard range.lowerBound < range.upperBound else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }
        let byteCount = range.upperBound - range.lowerBound
        guard range.upperBound > 0,
              range.upperBound <= totalCiphertextSize,
              byteCount <= UInt64(Int.max) else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }
        var grant = try await grantStore.grant(for: assetId)
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = URLRequest(url: grant.grantURL)
            request.httpMethod = "GET"
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
            telemetry.recordRangeRequest()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw E2eeRangeStreamingResourceError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                guard attempt == 0,
                      let renewed = await grantStore.handleUnauthorized(
                        assetId: assetId,
                        httpStatus: http.statusCode,
                        grantAttempt: attempt,
                        failedGrantURL: grant.grantURL,
                        fallback: { _ in }
                      ) else {
                    throw E2eeRangeStreamingResourceError.invalidResponse
                }
                grant = renewed
                continue
            }
            guard http.statusCode == 206,
                  data.count == Int(byteCount),
                  Self.hasExactContentLength(http, expected: byteCount),
                  Self.hasExactContentRange(
                    http,
                    expected: range,
                    totalCiphertextSize: totalCiphertextSize
                  ) else {
                throw E2eeRangeStreamingResourceError.invalidContentRange
            }
            telemetry.recordCiphertextBytes(data.count)
            return data
        }
        throw E2eeRangeStreamingResourceError.invalidResponse
    }

    func invalidate(assetId: String) async {
        session.invalidateAndCancel()
        await grantStore.invalidateSession(for: assetId)
    }

    private static func hasExactContentLength(
        _ response: HTTPURLResponse,
        expected: UInt64
    ) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length"),
              let value = UInt64(raw.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return value == expected
    }

    private static func hasExactContentRange(
        _ response: HTTPURLResponse,
        expected: Range<UInt64>,
        totalCiphertextSize: UInt64
    ) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Range") else {
            return false
        }
        let components = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2,
              components[0].lowercased() == "bytes" else {
            return false
        }
        let rangeAndTotal = components[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else { return false }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let lower = UInt64(bounds[0]),
              let upper = UInt64(bounds[1]),
              lower == expected.lowerBound,
              upper == expected.upperBound - 1 else {
            return false
        }
        return rangeAndTotal[1] == "*" || UInt64(rangeAndTotal[1]) == totalCiphertextSize
    }
}

private actor E2eeRangeFallbackFile {
    typealias Provider = @Sendable () async throws -> E2eeAttachmentOriginalLease

    private let provider: Provider
    private var lease: E2eeAttachmentOriginalLease?
    private var task: Task<E2eeAttachmentOriginalLease, Error>?

    init(provider: @escaping Provider) {
        self.provider = provider
    }

    func localURL() async throws -> URL {
        if let lease { return lease.localURL }
        let active: Task<E2eeAttachmentOriginalLease, Error>
        if let task {
            active = task
        } else {
            let provider = provider
            active = Task { try await provider() }
            task = active
        }
        do {
            let lease = try await active.value
            self.lease = lease
            task = nil
            return lease.localURL
        } catch {
            task = nil
            throw error
        }
    }

    func release() {
        task?.cancel()
        task = nil
        lease?.release()
        lease = nil
    }
}

private final class E2eeRangeFrameWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var handler: (@Sendable () -> Void)?

    func install(_ handler: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock { () -> Bool in
            if isCancelled { return true }
            self.handler = handler
            return false
        }
        if shouldCancel { handler() }
    }

    func cancel() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            isCancelled = true
            let current = self.handler
            self.handler = nil
            return current
        }
        handler?()
    }
}

/// Per-playback frame cache and in-flight registry. Plaintext never leaves process memory.
actor E2eeRangePlaintextFrameStore {
    typealias CiphertextFetcher = @Sendable (Range<UInt64>) async throws -> Data

    static let defaultCacheCostLimit = 16 * 1024 * 1024
    static let maximumFrameBatch = 8

    private struct CacheEntry {
        let data: Data
        var accessSequence: UInt64
    }

    private struct Flight {
        let id: UUID
        let frameRange: ClosedRange<UInt64>
        let cacheGeneration: UInt64
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<[UInt64: Data], Error>]
    }

    private let asset: E2eeAttachmentManifestAssetV1
    private let contentKey: Data
    private let noncePrefix: Data
    private let fetcher: CiphertextFetcher
    private let cacheCostLimit: Int
    private let telemetry: E2eeRangeStreamingTelemetry
    private let frameCount: UInt64

    private var cache: [UInt64: CacheEntry] = [:]
    private var cacheCost = 0
    private var accessSequence: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var flights: [UUID: Flight] = [:]
    private var flightIdByFrame: [UInt64: UUID] = [:]
    private var previousDemand: Range<UInt64>?
    private var previousDemandWasSmall = false

    init(
        asset: E2eeAttachmentManifestAssetV1,
        cacheCostLimit: Int = defaultCacheCostLimit,
        telemetry: E2eeRangeStreamingTelemetry = .init(),
        fetcher: @escaping CiphertextFetcher
    ) throws {
        guard asset.kind == .original,
              asset.frameSize > 0,
              let plaintextSize = asset.plaintextSize,
              let contentKey = Data(base64Encoded: asset.contentKey),
              contentKey.count == E2eeAttachmentFrameCryptoV1.keySize,
              let noncePrefix = Data(base64Encoded: asset.noncePrefix),
              noncePrefix.count == E2eeAttachmentFrameCryptoV1.noncePrefixSize else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        self.asset = asset
        self.contentKey = contentKey
        self.noncePrefix = noncePrefix
        self.fetcher = fetcher
        self.cacheCostLimit = max(0, cacheCostLimit)
        self.telemetry = telemetry
        let frameSize = UInt64(asset.frameSize)
        let adjusted = plaintextSize.addingReportingOverflow(frameSize - 1)
        guard !adjusted.overflow else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        let computedFrameCount = max(1, adjusted.partialValue / frameSize)
        guard computedFrameCount <= UInt64(UInt32.max) + 1 else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        frameCount = computedFrameCount
    }

    /// Returns the first canonical batch. Extra frames are included only after two small,
    /// forward-moving demands establish sequential playback.
    func firstBatch(
        for plaintextRange: Range<UInt64>,
        firstFrame: UInt64,
        lastFrame: UInt64
    ) -> ClosedRange<UInt64> {
        let frameSize = UInt64(asset.frameSize)
        let isSmall = plaintextRange.upperBound - plaintextRange.lowerBound <= frameSize
        let isForwardSequential: Bool
        if let previousDemand {
            let upperWithSlack = previousDemand.upperBound.addingReportingOverflow(frameSize)
            isForwardSequential = previousDemandWasSmall
                && isSmall
                && plaintextRange.lowerBound > previousDemand.lowerBound
                && !upperWithSlack.overflow
                && plaintextRange.lowerBound <= upperWithSlack.partialValue
        } else {
            isForwardSequential = false
        }
        previousDemand = plaintextRange
        previousDemandWasSmall = isSmall

        let demandedEnd = min(lastFrame, firstFrame + UInt64(Self.maximumFrameBatch - 1))
        guard isForwardSequential else { return firstFrame...demandedEnd }
        let prefetchedEnd = min(frameCount - 1, firstFrame + UInt64(Self.maximumFrameBatch - 1))
        return firstFrame...max(demandedEnd, prefetchedEnd)
    }

    func frames(in requestedRange: ClosedRange<UInt64>) async throws -> [UInt64: Data] {
        guard requestedRange.lowerBound < frameCount,
              requestedRange.upperBound < frameCount,
              requestedRange.count <= Self.maximumFrameBatch else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }

        var output: [UInt64: Data] = [:]
        while output.count < requestedRange.count {
            try Task.checkCancellation()
            var firstMissing: UInt64?
            for frameIndex in requestedRange where output[frameIndex] == nil {
                if let cached = cachedFrame(frameIndex) {
                    output[frameIndex] = cached
                } else if firstMissing == nil {
                    firstMissing = frameIndex
                }
            }
            guard let firstMissing else { break }
            let fetched = try await waitForFlight(
                containing: firstMissing,
                preferredUpperBound: requestedRange.upperBound
            )
            for (frameIndex, data) in fetched where requestedRange.contains(frameIndex) {
                output[frameIndex] = data
            }
        }
        return output
    }

    func removeAllCachedFrames() {
        cache.removeAll()
        cacheCost = 0
        cacheGeneration &+= 1
    }

    func invalidate() {
        let activeTasks = flights.values.compactMap(\.task)
        let waiters = flights.values.flatMap { $0.waiters.values }
        flights.removeAll()
        flightIdByFrame.removeAll()
        removeAllCachedFrames()
        activeTasks.forEach { $0.cancel() }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }

    var cachedByteCount: Int { cacheCost }
    var cachedFrameCount: Int { cache.count }
    var activeFlightCount: Int { flights.count }
    var activeWaiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }

    private func cachedFrame(_ frameIndex: UInt64) -> Data? {
        guard var entry = cache[frameIndex] else { return nil }
        accessSequence &+= 1
        entry.accessSequence = accessSequence
        cache[frameIndex] = entry
        telemetry.recordCacheHit(bytes: entry.data.count)
        return entry.data
    }

    private func waitForFlight(
        containing frameIndex: UInt64,
        preferredUpperBound: UInt64
    ) async throws -> [UInt64: Data] {
        let waiterId = UUID()
        let cancellation = E2eeRangeFrameWaiterCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let flightId = registerWaiter(
                    waiterId: waiterId,
                    continuation: continuation,
                    frameIndex: frameIndex,
                    preferredUpperBound: preferredUpperBound
                )
                cancellation.install { [weak self] in
                    Task { await self?.cancelWaiter(waiterId, flightId: flightId) }
                }
                if Task.isCancelled { cancellation.cancel() }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func registerWaiter(
        waiterId: UUID,
        continuation: CheckedContinuation<[UInt64: Data], Error>,
        frameIndex: UInt64,
        preferredUpperBound: UInt64
    ) -> UUID {
        if let existingId = flightIdByFrame[frameIndex],
           var existing = flights[existingId] {
            existing.waiters[waiterId] = continuation
            flights[existingId] = existing
            return existingId
        }

        var upperBound = frameIndex
        while upperBound < preferredUpperBound {
            let candidate = upperBound + 1
            guard cache[candidate] == nil,
                  flightIdByFrame[candidate] == nil else { break }
            upperBound = candidate
        }
        let flightId = UUID()
        let frameRange = frameIndex...upperBound
        flights[flightId] = Flight(
            id: flightId,
            frameRange: frameRange,
            cacheGeneration: cacheGeneration,
            task: nil,
            waiters: [waiterId: continuation]
        )
        for index in frameRange {
            flightIdByFrame[index] = flightId
        }

        let asset = asset
        let key = contentKey
        let noncePrefix = noncePrefix
        let fetcher = fetcher
        let task = Task { [weak self] in
            let result: Result<[UInt64: Data], Error>
            do {
                let cipherRange = try Self.ciphertextRange(
                    for: frameRange,
                    asset: asset
                )
                let ciphertext = try await fetcher(cipherRange)
                let frames = try Self.decryptFrames(
                    ciphertext,
                    frameRange: frameRange,
                    asset: asset,
                    contentKey: key,
                    noncePrefix: noncePrefix
                )
                result = .success(frames)
            } catch {
                result = .failure(error)
            }
            await self?.completeFlight(flightId, result: result)
        }
        flights[flightId]?.task = task
        return flightId
    }

    private func cancelWaiter(_ waiterId: UUID, flightId: UUID) {
        guard var flight = flights[flightId],
              let continuation = flight.waiters.removeValue(forKey: waiterId) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            removeFlight(flight)
        } else {
            flights[flightId] = flight
        }
    }

    private func completeFlight(
        _ flightId: UUID,
        result: Result<[UInt64: Data], Error>
    ) {
        guard let flight = flights[flightId] else { return }
        removeFlight(flight)
        switch result {
        case let .success(frames):
            if flight.cacheGeneration == cacheGeneration {
                for (frameIndex, data) in frames {
                    insertCachedFrame(data, frameIndex: frameIndex)
                }
            }
            flight.waiters.values.forEach { $0.resume(returning: frames) }
        case let .failure(error):
            flight.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

    private func removeFlight(_ flight: Flight) {
        flights[flight.id] = nil
        for frameIndex in flight.frameRange where flightIdByFrame[frameIndex] == flight.id {
            flightIdByFrame[frameIndex] = nil
        }
    }

    private func insertCachedFrame(_ data: Data, frameIndex: UInt64) {
        guard cacheCostLimit > 0, data.count <= cacheCostLimit else { return }
        if let replaced = cache.removeValue(forKey: frameIndex) {
            cacheCost -= replaced.data.count
        }
        accessSequence &+= 1
        cache[frameIndex] = CacheEntry(data: data, accessSequence: accessSequence)
        cacheCost += data.count
        while cacheCost > cacheCostLimit,
              let victim = cache.min(by: { $0.value.accessSequence < $1.value.accessSequence }) {
            cache[victim.key] = nil
            cacheCost -= victim.value.data.count
        }
    }

    private static func ciphertextRange(
        for frameRange: ClosedRange<UInt64>,
        asset: E2eeAttachmentManifestAssetV1
    ) throws -> Range<UInt64> {
        guard let plaintextSize = asset.plaintextSize else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        let stride = UInt64(asset.frameSize)
            + UInt64(E2eeAttachmentFrameCryptoV1.headerSize + E2eeAttachmentFrameCryptoV1.tagSize)
        let start = frameRange.lowerBound.multipliedReportingOverflow(by: stride)
        let lastStart = frameRange.upperBound.multipliedReportingOverflow(by: stride)
        guard !start.overflow, !lastStart.overflow else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }
        let lastLength = plaintextLength(
            frameIndex: frameRange.upperBound,
            asset: asset,
            plaintextSize: plaintextSize
        ) + UInt64(E2eeAttachmentFrameCryptoV1.headerSize + E2eeAttachmentFrameCryptoV1.tagSize)
        let end = lastStart.partialValue.addingReportingOverflow(lastLength)
        guard !end.overflow, end.partialValue <= asset.cipherSize else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }
        return start.partialValue..<end.partialValue
    }

    private static func decryptFrames(
        _ ciphertext: Data,
        frameRange: ClosedRange<UInt64>,
        asset: E2eeAttachmentManifestAssetV1,
        contentKey: Data,
        noncePrefix: Data
    ) throws -> [UInt64: Data] {
        guard let plaintextSize = asset.plaintextSize else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        var output: [UInt64: Data] = [:]
        var cursor = 0
        for frameIndex in frameRange {
            try Task.checkCancellation()
            let plainLength = plaintextLength(
                frameIndex: frameIndex,
                asset: asset,
                plaintextSize: plaintextSize
            )
            let storedLength = Int(plainLength)
                + E2eeAttachmentFrameCryptoV1.headerSize
                + E2eeAttachmentFrameCryptoV1.tagSize
            guard cursor + storedLength <= ciphertext.count else {
                throw E2eeRangeStreamingResourceError.invalidFrame
            }
            let frame = ciphertext.subdata(in: cursor..<(cursor + storedLength))
            cursor += storedLength
            output[frameIndex] = try decryptFrame(
                frame,
                expectedPlaintextLength: Int(plainLength),
                frameIndex: UInt32(frameIndex),
                contentKey: contentKey,
                noncePrefix: noncePrefix
            )
        }
        guard cursor == ciphertext.count else {
            throw E2eeRangeStreamingResourceError.invalidFrame
        }
        return output
    }

    private static func plaintextLength(
        frameIndex: UInt64,
        asset: E2eeAttachmentManifestAssetV1,
        plaintextSize: UInt64
    ) -> UInt64 {
        let start = frameIndex * UInt64(asset.frameSize)
        return min(UInt64(asset.frameSize), plaintextSize - start)
    }

    private static func decryptFrame(
        _ frame: Data,
        expectedPlaintextLength: Int,
        frameIndex: UInt32,
        contentKey: Data,
        noncePrefix: Data
    ) throws -> Data {
        guard frame.count == expectedPlaintextLength
            + E2eeAttachmentFrameCryptoV1.headerSize
            + E2eeAttachmentFrameCryptoV1.tagSize else {
            throw E2eeRangeStreamingResourceError.invalidFrame
        }
        let plainLength = readUInt32(frame, offset: 0)
        let cipherLength = readUInt32(frame, offset: 4)
        guard plainLength == UInt32(expectedPlaintextLength),
              cipherLength == UInt32(expectedPlaintextLength + E2eeAttachmentFrameCryptoV1.tagSize) else {
            throw E2eeRangeStreamingResourceError.invalidFrame
        }
        let body = frame.dropFirst(E2eeAttachmentFrameCryptoV1.headerSize)
        let ciphertext = body.dropLast(E2eeAttachmentFrameCryptoV1.tagSize)
        let tag = body.suffix(E2eeAttachmentFrameCryptoV1.tagSize)
        var nonce = noncePrefix
        nonce.append(UInt8((frameIndex >> 24) & 0xff))
        nonce.append(UInt8((frameIndex >> 16) & 0xff))
        nonce.append(UInt8((frameIndex >> 8) & 0xff))
        nonce.append(UInt8(frameIndex & 0xff))
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealed, using: SymmetricKey(data: contentKey))
        } catch {
            throw E2eeRangeStreamingResourceError.invalidFrame
        }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}

/// Keeps a resource-loading task suspended until it is registered under the loader lock.
/// AVFoundation is allowed to cancel a request from the delegate queue immediately, so starting
/// an unregistered task can otherwise leave a request running after `didCancel` has returned.
final class E2eeRangeLoadingRequestStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let resolved = lock.withLock { () -> Bool? in
                if let resolution { return resolution }
                self.continuation = continuation
                return nil
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }

    func resolve(_ shouldStart: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard resolution == nil else { return nil }
            resolution = shouldStart
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(returning: shouldStart)
    }
}

final class E2eeRangeStreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    typealias GrantProvider = E2eeRangeStreamingGrantStore.GrantProvider

    private static let scheme = "ermis-e2ee-stream"

    private let asset: E2eeAttachmentManifestAssetV1
    private let streamURL: URL
    private let reader: E2eeRangeCiphertextReader
    private let frameStore: E2eeRangePlaintextFrameStore
    private let fallback: E2eeRangeFallbackFile
    private let telemetry: E2eeRangeStreamingTelemetry
    private let loadingRequestCancellationHandler: @Sendable () -> Void
    private let loadingRequestObserver: (AVAssetResourceLoadingRequest) -> Void
    private let lock = NSLock()
    private struct ActiveLoadingRequest {
        let token: UUID
        let startGate: E2eeRangeLoadingRequestStartGate
        var task: Task<Void, Never>?
    }

    private var activeLoadingRequests: [ObjectIdentifier: ActiveLoadingRequest] = [:]
    private var isInvalidated = false
#if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
#endif

    init(
        asset: E2eeAttachmentManifestAssetV1,
        grantProvider: @escaping GrantProvider,
        fallbackProvider: @escaping @Sendable () async throws -> E2eeAttachmentOriginalLease,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        cacheCostLimit: Int = E2eeRangePlaintextFrameStore.defaultCacheCostLimit,
        telemetry: E2eeRangeStreamingTelemetry = .init(),
        loadingRequestCancellationHandler: @escaping @Sendable () -> Void = {},
        loadingRequestObserver: @escaping (AVAssetResourceLoadingRequest) -> Void = { _ in }
    ) throws {
        guard let streamURL = URL(string: "\(Self.scheme)://asset/\(UUID().uuidString)") else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        self.asset = asset
        self.streamURL = streamURL
        self.telemetry = telemetry
        self.loadingRequestCancellationHandler = loadingRequestCancellationHandler
        self.loadingRequestObserver = loadingRequestObserver
        let grantStore = E2eeRangeStreamingGrantStore(
            grantProvider: grantProvider,
            eventHandler: { telemetry.recordGrantEvent($0) }
        )
        let reader = E2eeRangeCiphertextReader(
            grantStore: grantStore,
            sessionConfiguration: sessionConfiguration,
            telemetry: telemetry
        )
        self.reader = reader
        frameStore = try E2eeRangePlaintextFrameStore(
            asset: asset,
            cacheCostLimit: cacheCostLimit,
            telemetry: telemetry,
            fetcher: { range in
                try await reader.read(
                    assetId: asset.assetId,
                    range: range,
                    totalCiphertextSize: asset.cipherSize
                )
            }
        )
        fallback = E2eeRangeFallbackFile(provider: fallbackProvider)
        super.init()
#if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak frameStore] _ in
            Task { await frameStore?.removeAllCachedFrames() }
        }
#endif
    }

    deinit {
#if canImport(UIKit)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
#endif
    }

    func makeAsset() -> AVURLAsset {
        AVURLAsset(url: streamURL)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        loadingRequestObserver(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        let token = UUID()
        let startGate = E2eeRangeLoadingRequestStartGate()
        let startedAt = Date()
        let accepted = lock.withLock { () -> Bool in
            guard !isInvalidated else { return false }
            activeLoadingRequests[key] = ActiveLoadingRequest(
                token: token,
                startGate: startGate,
                task: nil
            )
            return true
        }
        guard accepted else { return false }

        let task = Task { [weak self, loadingRequest] in
            guard await startGate.wait(), let self else { return }
            defer { self.removeTask(for: key, token: token) }
            do {
                try await self.fulfill(loadingRequest)
                self.telemetry.recordLoadingRequest(latency: Date().timeIntervalSince(startedAt))
                loadingRequest.finishLoading()
            } catch is CancellationError {
                // AVFoundation has already finished a request delivered through `didCancel`.
                // Calling `finishLoading(with:)` here produces a double-finish warning and can
                // race a replacement seek. Cancellation is terminal and writes no more bytes.
            } catch {
                self.telemetry.recordFallback(Self.fallbackReason(for: error))
                do {
                    try await self.fulfillFromFallback(loadingRequest)
                    self.telemetry.recordLoadingRequest(latency: Date().timeIntervalSince(startedAt))
                    loadingRequest.finishLoading()
                } catch {
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
        let installed = lock.withLock { () -> Bool in
            guard var active = activeLoadingRequests[key],
                  active.token == token,
                  !isInvalidated else {
                return false
            }
            active.task = task
            activeLoadingRequests[key] = active
            return true
        }
        startGate.resolve(installed)
        if !installed {
            task.cancel()
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        let active = lock.withLock { activeLoadingRequests.removeValue(forKey: key) }
        log.debug(
            "[E2EE_RANGE_PLAYBACK] request=cancelled",
            subsystems: .mls
        )
        loadingRequestCancellationHandler()
        active?.startGate.resolve(false)
        active?.task?.cancel()
    }

    func invalidate() {
        let active: [ActiveLoadingRequest]? = lock.withLock {
            guard !isInvalidated else { return nil }
            isInvalidated = true
            let values = Array(activeLoadingRequests.values)
            activeLoadingRequests.removeAll()
            return values
        }
        guard let active else { return }
        active.forEach {
            $0.startGate.resolve(false)
            $0.task?.cancel()
        }
#if canImport(UIKit)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
        }
#endif
        let reader = reader
        let frameStore = frameStore
        let fallback = fallback
        let assetId = asset.assetId
        let telemetry = telemetry
        Task {
            await frameStore.invalidate()
            await reader.invalidate(assetId: assetId)
            await fallback.release()
            log.info(
                E2eeRangeStreamingTelemetry.summary(telemetry.snapshot()),
                subsystems: .mls
            )
        }
    }

    private func removeTask(for key: ObjectIdentifier, token: UUID) {
        _ = lock.withLock {
            guard activeLoadingRequests[key]?.token == token else { return }
            activeLoadingRequests.removeValue(forKey: key)
        }
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest) async throws {
        guard let plaintextSize = asset.plaintextSize else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        populateContentInformation(request.contentInformationRequest, plaintextSize: plaintextSize)
        guard let dataRequest = request.dataRequest else { return }
        guard let range = requestedRange(dataRequest, plaintextSize: plaintextSize) else { return }
        try await streamPlaintext(range: range, to: dataRequest)
    }

    private func streamPlaintext(
        range: Range<UInt64>,
        to request: AVAssetResourceLoadingDataRequest
    ) async throws {
        guard !range.isEmpty else { return }
        let frameSize = UInt64(asset.frameSize)
        let firstFrame = range.lowerBound / frameSize
        let lastFrame = (range.upperBound - 1) / frameSize
        let firstBatch = await frameStore.firstBatch(
            for: range,
            firstFrame: firstFrame,
            lastFrame: lastFrame
        )
        var batchStart = firstFrame
        while batchStart <= lastFrame {
            try Task.checkCancellation()
            let demandedEnd = min(
                lastFrame,
                batchStart + UInt64(E2eeRangePlaintextFrameStore.maximumFrameBatch - 1)
            )
            let fetchEnd = batchStart == firstFrame
                ? max(demandedEnd, firstBatch.upperBound)
                : demandedEnd
            let frames = try await frameStore.frames(in: batchStart...fetchEnd)
            for frameIndex in batchStart...demandedEnd {
                try Task.checkCancellation()
                guard let plaintext = frames[frameIndex] else {
                    throw E2eeRangeStreamingResourceError.invalidFrame
                }
                let framePlainStart = frameIndex * frameSize
                let overlapStart = max(range.lowerBound, framePlainStart)
                let overlapEnd = min(range.upperBound, framePlainStart + UInt64(plaintext.count))
                if overlapStart < overlapEnd {
                    let lower = Int(overlapStart - framePlainStart)
                    let upper = Int(overlapEnd - framePlainStart)
                    try Task.checkCancellation()
                    request.respond(with: plaintext.subdata(in: lower..<upper))
                }
            }
            batchStart = demandedEnd + 1
        }
    }

    private func fulfillFromFallback(_ request: AVAssetResourceLoadingRequest) async throws {
        guard let plaintextSize = asset.plaintextSize else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        populateContentInformation(request.contentInformationRequest, plaintextSize: plaintextSize)
        guard let dataRequest = request.dataRequest else { return }
        guard let range = requestedRange(dataRequest, plaintextSize: plaintextSize) else { return }
        let url = try await fallback.localURL()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.lowerBound)
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(remaining, 512 * 1024))) ?? Data()
            guard !chunk.isEmpty else {
                throw E2eeRangeStreamingResourceError.invalidResponse
            }
            dataRequest.respond(with: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    private func requestedRange(
        _ request: AVAssetResourceLoadingDataRequest,
        plaintextSize: UInt64
    ) -> Range<UInt64>? {
        let requestedStart = UInt64(max(0, request.requestedOffset))
        let current = UInt64(max(request.requestedOffset, request.currentOffset))
        guard current < plaintextSize else { return nil }
        let requestedEnd: UInt64
        if request.requestsAllDataToEndOfResource {
            requestedEnd = plaintextSize
        } else {
            let addition = requestedStart.addingReportingOverflow(
                UInt64(max(0, request.requestedLength))
            )
            requestedEnd = addition.overflow
                ? plaintextSize
                : min(plaintextSize, addition.partialValue)
        }
        guard current < requestedEnd else { return nil }
        return current..<requestedEnd
    }

    private func populateContentInformation(
        _ information: AVAssetResourceLoadingContentInformationRequest?,
        plaintextSize: UInt64
    ) {
        guard let information else { return }
        information.contentLength = Int64(clamping: plaintextSize)
        information.isByteRangeAccessSupported = true
        if let mime = asset.display?["mime_type"]?.stringValue {
            information.contentType = UTType(mimeType: mime)?.identifier
        }
    }

    private static func fallbackReason(for error: Error) -> E2eeRangeStreamingFallbackReason {
        if error is URLError { return .transport }
        if let rangeError = error as? E2eeRangeStreamingResourceError {
            switch rangeError {
            case .invalidFrame:
                return .frameIntegrity
            case .invalidManifest, .invalidRange, .invalidResponse, .invalidContentRange:
                return .responseContract
            }
        }
        return .unknown
    }
}
