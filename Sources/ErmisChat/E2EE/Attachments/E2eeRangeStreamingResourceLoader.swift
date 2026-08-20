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

enum E2eeRangeMediaTypeSource: String, Sendable {
    case manifestMime
    case manifestName
    case attachmentMime
    case attachmentName
    case videoDefault
}

enum E2eeRangeLoadingRequestRegion: String, Sendable {
    case head
    case middle
    case tail
}

struct E2eeRangeMediaDescription: Equatable, Sendable {
    let contentTypeIdentifier: String
    let fileExtension: String
    let source: E2eeRangeMediaTypeSource

    static func resolve(
        asset: E2eeAttachmentManifestAssetV1,
        attachmentMimeType: String?,
        attachmentFileName: String?
    ) -> Self {
        if let value = videoType(mimeType: asset.display?["mime_type"]?.stringValue) {
            return description(type: value, source: .manifestMime)
        }
        if let value = videoType(fileName: asset.display?["name"]?.stringValue) {
            return description(type: value, source: .manifestName)
        }
        if let value = videoType(mimeType: attachmentMimeType) {
            return description(type: value, source: .attachmentMime)
        }
        if let value = videoType(fileName: attachmentFileName) {
            return description(type: value, source: .attachmentName)
        }
        return description(type: .mpeg4Movie, source: .videoDefault)
    }

    private static func videoType(mimeType: String?) -> UTType? {
        guard let mimeType,
              let type = UTType(mimeType: mimeType),
              type.conforms(to: .audiovisualContent) else { return nil }
        return type
    }

    private static func videoType(fileName: String?) -> UTType? {
        guard let fileName else { return nil }
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension),
              type.conforms(to: .audiovisualContent) else { return nil }
        return type
    }

    private static func description(type: UTType, source: E2eeRangeMediaTypeSource) -> Self {
        let fileExtension = type.preferredFilenameExtension?.lowercased() ?? "mp4"
        return .init(
            contentTypeIdentifier: type.identifier,
            fileExtension: fileExtension,
            source: source
        )
    }
}

/// Lock-backed because grant, URLSession and AVFoundation callbacks arrive on different executors.
/// The snapshot and log line intentionally contain counters and fixed categories only.
enum E2eeRangeStreamingTransportClass: Sendable {
    case priority
    case continuation
}

final class E2eeRangeStreamingTelemetry: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var initialGrantRequests = 0
        var grantRenewalRequests = 0
        var rangeRequests = 0
        var priorityTransportRequests = 0
        var continuationTransportRequests = 0
        var connectivityWaitCount = 0
        var ciphertextBytes = 0
        var cacheHitBytes = 0
        var completedLoadingRequests = 0
        var startupLatencyMilliseconds = 0
        var maximumSeekLatencyMilliseconds = 0
        var firstResponseCount = 0
        var maximumFirstResponseLatencyMilliseconds = 0
        var maximumHeadFirstResponseLatencyMilliseconds = 0
        var maximumMiddleFirstResponseLatencyMilliseconds = 0
        var maximumTailFirstResponseLatencyMilliseconds = 0
        var priorityBypassCount = 0
        var boundedLoadingRequests = 0
        var allToEndLoadingRequests = 0
        var headLoadingRequests = 0
        var middleLoadingRequests = 0
        var tailLoadingRequests = 0
        var maximumActiveLoadingRequests = 0
        var mediaTypeSource: E2eeRangeMediaTypeSource = .videoDefault
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

    func recordRangeRequest(
        transport: E2eeRangeStreamingTransportClass = .continuation
    ) {
        lock.withLock {
            value.rangeRequests += 1
            switch transport {
            case .priority:
                value.priorityTransportRequests += 1
            case .continuation:
                value.continuationTransportRequests += 1
            }
        }
    }

    func recordCiphertextBytes(_ ciphertextBytes: Int) {
        lock.withLock {
            value.ciphertextBytes += max(0, ciphertextBytes)
        }
    }

    func recordConnectivityWait() {
        lock.withLock { value.connectivityWaitCount += 1 }
        log.info(
            "[E2EE_RANGE_PLAYBACK] state=waiting_for_connectivity",
            subsystems: .mls
        )
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

    func recordLoadingRequestShape(
        range: Range<UInt64>,
        plaintextSize: UInt64,
        frameSize: UInt64,
        requestsAllDataToEnd: Bool
    ) -> E2eeRangeLoadingRequestRegion {
        let batchWindow = frameSize.multipliedReportingOverflow(
            by: UInt64(E2eeRangePlaintextFrameStore.maximumFrameBatch)
        )
        let edgeWindow = batchWindow.overflow
            ? plaintextSize
            : min(plaintextSize, batchWindow.partialValue)
        return lock.withLock {
            if requestsAllDataToEnd {
                value.allToEndLoadingRequests += 1
            } else {
                value.boundedLoadingRequests += 1
            }
            if range.lowerBound < edgeWindow {
                value.headLoadingRequests += 1
                return .head
            } else if range.upperBound > plaintextSize - edgeWindow {
                value.tailLoadingRequests += 1
                return .tail
            } else {
                value.middleLoadingRequests += 1
                return .middle
            }
        }
    }

    func recordFirstResponse(
        latency: TimeInterval,
        region: E2eeRangeLoadingRequestRegion,
        requestsAllDataToEnd: Bool
    ) {
        let milliseconds = max(0, Int((latency * 1_000).rounded()))
        lock.withLock {
            value.firstResponseCount += 1
            value.maximumFirstResponseLatencyMilliseconds = max(
                value.maximumFirstResponseLatencyMilliseconds,
                milliseconds
            )
            switch region {
            case .head:
                value.maximumHeadFirstResponseLatencyMilliseconds = max(
                    value.maximumHeadFirstResponseLatencyMilliseconds,
                    milliseconds
                )
            case .middle:
                value.maximumMiddleFirstResponseLatencyMilliseconds = max(
                    value.maximumMiddleFirstResponseLatencyMilliseconds,
                    milliseconds
                )
            case .tail:
                value.maximumTailFirstResponseLatencyMilliseconds = max(
                    value.maximumTailFirstResponseLatencyMilliseconds,
                    milliseconds
                )
            }
        }
        let requestMode = requestsAllDataToEnd ? "all_to_end" : "bounded"
        log.info(
            "[E2EE_RANGE_PLAYBACK] state=first_response region=\(region.rawValue) "
                + "request=\(requestMode) latency_ms=\(milliseconds)",
            subsystems: .mls
        )
    }

    func recordActiveLoadingRequestCount(_ count: Int) {
        lock.withLock {
            value.maximumActiveLoadingRequests = max(value.maximumActiveLoadingRequests, count)
        }
    }

    func recordPriorityBypass() {
        lock.withLock { value.priorityBypassCount += 1 }
        log.info(
            "[E2EE_RANGE_PLAYBACK] state=priority_bypass",
            subsystems: .mls
        )
    }

    func recordMediaTypeSource(_ source: E2eeRangeMediaTypeSource) {
        lock.withLock { value.mediaTypeSource = source }
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
            + "priority_transport_requests=\(snapshot.priorityTransportRequests) "
            + "continuation_transport_requests=\(snapshot.continuationTransportRequests) "
            + "connectivity_waits=\(snapshot.connectivityWaitCount) "
            + "ciphertext_bytes=\(snapshot.ciphertextBytes) cache_hit_bytes=\(snapshot.cacheHitBytes) "
            + "completed_requests=\(snapshot.completedLoadingRequests) "
            + "startup_ms=\(snapshot.startupLatencyMilliseconds) "
            + "max_seek_ms=\(snapshot.maximumSeekLatencyMilliseconds) "
            + "first_responses=\(snapshot.firstResponseCount) "
            + "max_first_response_ms=\(snapshot.maximumFirstResponseLatencyMilliseconds) "
            + "head_first_response_ms=\(snapshot.maximumHeadFirstResponseLatencyMilliseconds) "
            + "middle_first_response_ms=\(snapshot.maximumMiddleFirstResponseLatencyMilliseconds) "
            + "tail_first_response_ms=\(snapshot.maximumTailFirstResponseLatencyMilliseconds) "
            + "priority_bypasses=\(snapshot.priorityBypassCount) "
            + "bounded_requests=\(snapshot.boundedLoadingRequests) "
            + "all_to_end_requests=\(snapshot.allToEndLoadingRequests) "
            + "head_requests=\(snapshot.headLoadingRequests) "
            + "middle_requests=\(snapshot.middleLoadingRequests) "
            + "tail_requests=\(snapshot.tailLoadingRequests) "
            + "max_active_requests=\(snapshot.maximumActiveLoadingRequests) "
            + "media_type_source=\(snapshot.mediaTypeSource.rawValue) "
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

private final class E2eeRangeStreamingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event {
        case response(HTTPURLResponse)
        case data(Data)
    }

    struct Stream {
        let events: AsyncThrowingStream<Event, Error>
        let task: URLSessionDataTask
    }

    private let lock = NSLock()
    private let telemetry: E2eeRangeStreamingTelemetry
    private var continuations: [Int: AsyncThrowingStream<Event, Error>.Continuation] = [:]

    init(telemetry: E2eeRangeStreamingTelemetry) {
        self.telemetry = telemetry
    }

    func stream(for request: URLRequest, using session: URLSession) -> Stream {
        var continuation: AsyncThrowingStream<Event, Error>.Continuation!
        let events = AsyncThrowingStream<Event, Error> { continuation = $0 }
        let task = session.dataTask(with: request)
        let taskIdentifier = task.taskIdentifier
        lock.withLock { continuations[taskIdentifier] = continuation }
        continuation.onTermination = { [weak self, weak task] termination in
            guard case .cancelled = termination else { return }
            task?.cancel()
            self?.removeContinuation(for: taskIdentifier)
        }
        return Stream(events: events, task: task)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let continuation = continuation(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation(for: dataTask.taskIdentifier)?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        telemetry.recordConnectivityWait()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = removeContinuation(for: task.taskIdentifier) else { return }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func continuation(
        for taskIdentifier: Int
    ) -> AsyncThrowingStream<Event, Error>.Continuation? {
        lock.withLock { continuations[taskIdentifier] }
    }

    @discardableResult
    private func removeContinuation(
        for taskIdentifier: Int
    ) -> AsyncThrowingStream<Event, Error>.Continuation? {
        lock.withLock { continuations.removeValue(forKey: taskIdentifier) }
    }
}

actor E2eeRangeCiphertextReader {
    typealias ChunkConsumer = @Sendable (Data) async throws -> Void

    let grantStore: E2eeRangeStreamingGrantStore
    private let delegate: E2eeRangeStreamingSessionDelegate
    private let session: URLSession
    private let telemetry: E2eeRangeStreamingTelemetry
    private let transportClass: E2eeRangeStreamingTransportClass
    private let taskPriority: Float

    init(
        grantStore: E2eeRangeStreamingGrantStore,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        telemetry: E2eeRangeStreamingTelemetry = .init(),
        transportClass: E2eeRangeStreamingTransportClass = .continuation,
        taskPriority: Float = URLSessionTask.defaultPriority
    ) {
        self.grantStore = grantStore
        self.telemetry = telemetry
        self.transportClass = transportClass
        self.taskPriority = taskPriority
        let sessionConfiguration = Self.playbackSessionConfiguration(from: sessionConfiguration)
        let delegate = E2eeRangeStreamingSessionDelegate(telemetry: telemetry)
        self.delegate = delegate
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// A seek that starts while the device is offline must remain owned by AVFoundation until
    /// connectivity returns or AVFoundation cancels it. Failing immediately would route a
    /// temporary outage into whole-download fallback and can leave the media clock advancing while
    /// the decoder still displays its last frame.
    nonisolated static func playbackSessionConfiguration(
        from source: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        let configuration = (source.copy() as? URLSessionConfiguration) ?? source
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        return configuration
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
            telemetry.recordRangeRequest(transport: transportClass)
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

    /// Streams one exact HTTP Range without buffering the entire response body. Headers are
    /// validated before any ciphertext reaches the frame decoder, and the body must still end at
    /// the exact declared byte count. Each consumer chunk remains ciphertext until its complete
    /// frame has independently passed AES-GCM authentication.
    func stream(
        assetId: String,
        range: Range<UInt64>,
        totalCiphertextSize: UInt64,
        consume: ChunkConsumer
    ) async throws {
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
            telemetry.recordRangeRequest(transport: transportClass)
            let stream = delegate.stream(for: request, using: session)
            stream.task.priority = taskPriority
            stream.task.resume()

            var receivedByteCount: UInt64 = 0
            var responseWasValidated = false
            var unauthorizedStatus: Int?
            do {
                eventLoop: for try await event in stream.events {
                    try Task.checkCancellation()
                    switch event {
                    case let .response(http):
                        if http.statusCode == 401 || http.statusCode == 403 {
                            unauthorizedStatus = http.statusCode
                            stream.task.cancel()
                            break eventLoop
                        }
                        guard http.statusCode == 206,
                              Self.hasExactContentLength(http, expected: byteCount),
                              Self.hasExactContentRange(
                                http,
                                expected: range,
                                totalCiphertextSize: totalCiphertextSize
                              ) else {
                            stream.task.cancel()
                            throw E2eeRangeStreamingResourceError.invalidContentRange
                        }
                        responseWasValidated = true

                    case let .data(data):
                        guard responseWasValidated else {
                            stream.task.cancel()
                            throw E2eeRangeStreamingResourceError.invalidResponse
                        }
                        let nextCount = receivedByteCount.addingReportingOverflow(UInt64(data.count))
                        guard !nextCount.overflow, nextCount.partialValue <= byteCount else {
                            stream.task.cancel()
                            throw E2eeRangeStreamingResourceError.invalidContentRange
                        }
                        try await consume(data)
                        receivedByteCount = nextCount.partialValue
                    }
                }
            } catch {
                stream.task.cancel()
                if unauthorizedStatus == nil { throw error }
            }

            if let unauthorizedStatus {
                guard attempt == 0,
                      let renewed = await grantStore.handleUnauthorized(
                        assetId: assetId,
                        httpStatus: unauthorizedStatus,
                        grantAttempt: attempt,
                        failedGrantURL: grant.grantURL,
                        fallback: { _ in }
                      ) else {
                    throw E2eeRangeStreamingResourceError.invalidResponse
                }
                grant = renewed
                continue
            }

            guard responseWasValidated, receivedByteCount == byteCount else {
                throw E2eeRangeStreamingResourceError.invalidContentRange
            }
            telemetry.recordCiphertextBytes(Int(receivedByteCount))
            return
        }
        throw E2eeRangeStreamingResourceError.invalidResponse
    }

    func invalidate(assetId: String) async {
        session.invalidateAndCancel()
        await grantStore.invalidateSession(for: assetId)
    }

    nonisolated func invalidateTransport() {
        session.invalidateAndCancel()
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
    typealias CiphertextChunkConsumer = @Sendable (Data) async throws -> Void
    typealias CiphertextStreamer = @Sendable (
        Range<UInt64>,
        Bool,
        CiphertextChunkConsumer
    ) async throws -> Void

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
        let usesPriorityTransport: Bool
        var task: Task<Void, Never>?
        var waiters: [UUID: FrameWaiter]
        var owners: Set<UUID>
    }

    private struct FrameWaiter {
        let frameIndex: UInt64
        let continuation: CheckedContinuation<Data, Error>
    }

    private actor FrameStreamDecoder {
        private let frameRange: ClosedRange<UInt64>
        private let asset: E2eeAttachmentManifestAssetV1
        private let contentKey: Data
        private let noncePrefix: Data
        private let plaintextSize: UInt64
        private var nextFrameIndex: UInt64
        private var didFinishAllFrames = false
        private var buffer = Data()

        init(
            frameRange: ClosedRange<UInt64>,
            asset: E2eeAttachmentManifestAssetV1,
            contentKey: Data,
            noncePrefix: Data
        ) throws {
            guard let plaintextSize = asset.plaintextSize else {
                throw E2eeRangeStreamingResourceError.invalidManifest
            }
            self.frameRange = frameRange
            self.asset = asset
            self.contentKey = contentKey
            self.noncePrefix = noncePrefix
            self.plaintextSize = plaintextSize
            nextFrameIndex = frameRange.lowerBound
        }

        func consume(_ chunk: Data) throws -> [(UInt64, Data)] {
            try Task.checkCancellation()
            guard !chunk.isEmpty else { return [] }
            buffer.append(chunk)
            var output: [(UInt64, Data)] = []
            while !didFinishAllFrames, nextFrameIndex <= frameRange.upperBound {
                let plainLength = E2eeRangePlaintextFrameStore.plaintextLength(
                    frameIndex: nextFrameIndex,
                    asset: asset,
                    plaintextSize: plaintextSize
                )
                let storedLength = Int(plainLength)
                    + E2eeAttachmentFrameCryptoV1.headerSize
                    + E2eeAttachmentFrameCryptoV1.tagSize
                guard buffer.count >= storedLength else { break }
                let encryptedFrame = buffer.subdata(in: 0..<storedLength)
                buffer.removeSubrange(0..<storedLength)
                let plaintext = try E2eeRangePlaintextFrameStore.decryptFrame(
                    encryptedFrame,
                    expectedPlaintextLength: Int(plainLength),
                    frameIndex: UInt32(nextFrameIndex),
                    contentKey: contentKey,
                    noncePrefix: noncePrefix
                )
                output.append((nextFrameIndex, plaintext))
                if nextFrameIndex == frameRange.upperBound {
                    didFinishAllFrames = true
                    break
                }
                nextFrameIndex += 1
            }
            return output
        }

        func finish() throws {
            try Task.checkCancellation()
            guard didFinishAllFrames,
                  buffer.isEmpty else {
                throw E2eeRangeStreamingResourceError.invalidFrame
            }
        }
    }

    private let asset: E2eeAttachmentManifestAssetV1
    private let contentKey: Data
    private let noncePrefix: Data
    private let streamer: CiphertextStreamer
    private let cacheCostLimit: Int
    private let telemetry: E2eeRangeStreamingTelemetry
    private let frameCount: UInt64

    private var cache: [UInt64: CacheEntry] = [:]
    private var cacheCost = 0
    private var accessSequence: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var flights: [UUID: Flight] = [:]
    private var flightIdByFrame: [UInt64: UUID] = [:]
    private var priorityFlightIdByFrame: [UInt64: UUID] = [:]

    init(
        asset: E2eeAttachmentManifestAssetV1,
        cacheCostLimit: Int = defaultCacheCostLimit,
        telemetry: E2eeRangeStreamingTelemetry = .init(),
        fetcher: @escaping CiphertextFetcher
    ) throws {
        try self.init(
            asset: asset,
            cacheCostLimit: cacheCostLimit,
            telemetry: telemetry,
            streamingFetcher: { range, _, consume in
                try await consume(try await fetcher(range))
            }
        )
    }

    init(
        asset: E2eeAttachmentManifestAssetV1,
        cacheCostLimit: Int = defaultCacheCostLimit,
        telemetry: E2eeRangeStreamingTelemetry = .init(),
        streamingFetcher: @escaping CiphertextStreamer
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
        streamer = streamingFetcher
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

    /// Returns one bounded batch for both first response and continuation work. The streaming
    /// decoder publishes the first authenticated frame before the rest of the Range body arrives,
    /// so splitting that frame into a second HTTP request only amplifies network scheduling.
    func batch(
        firstFrame: UInt64,
        lastFrame: UInt64,
        prioritizingFirstResponse _: Bool
    ) -> ClosedRange<UInt64> {
        let end = min(lastFrame, firstFrame + UInt64(Self.maximumFrameBatch - 1))
        return firstFrame...end
    }

    func frames(
        in requestedRange: ClosedRange<UInt64>,
        prioritizingFirstResponse: Bool = false
    ) async throws -> [UInt64: Data] {
        var output: [UInt64: Data] = [:]
        try await consumeFrames(
            in: requestedRange,
            prioritizingFirstResponse: prioritizingFirstResponse
        ) { frameIndex, frame in
            output[frameIndex] = frame
        }
        return output
    }

    /// Keeps one bounded flight owned for the whole AVFoundation batch while yielding verified
    /// frames in plaintext order. The first complete frame can therefore reach the player before
    /// the rest of the HTTP Range body has arrived.
    func consumeFrames(
        in requestedRange: ClosedRange<UInt64>,
        prioritizingFirstResponse: Bool = false,
        consume: (UInt64, Data) async throws -> Void
    ) async throws {
        guard requestedRange.lowerBound < frameCount,
              requestedRange.upperBound < frameCount,
              requestedRange.count <= Self.maximumFrameBatch else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }

        let ownerId = UUID()
        let firstMissingFrame = requestedRange.first { cache[$0] == nil }
        let ownedFlightId = firstMissingFrame.map {
            acquireFlightOwner(
                ownerId: ownerId,
                containing: $0,
                preferredUpperBound: requestedRange.upperBound,
                prioritizingFirstResponse: prioritizingFirstResponse
            )
        }
        do {
            try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
                for frameIndex in requestedRange {
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        let frame = try await self.frame(
                            at: frameIndex,
                            prefetchThrough: requestedRange.upperBound,
                            prioritizingFirstResponse: prioritizingFirstResponse
                                && frameIndex == firstMissingFrame
                        )
                        return (frameIndex, frame)
                    }
                }

                var nextFrameIndex = requestedRange.lowerBound
                var ready: [UInt64: Data] = [:]
                for try await (frameIndex, frame) in group {
                    ready[frameIndex] = frame
                    while let next = ready.removeValue(forKey: nextFrameIndex) {
                        try await consume(nextFrameIndex, next)
                        if nextFrameIndex == requestedRange.upperBound { break }
                        nextFrameIndex += 1
                    }
                }
            }
            if let ownedFlightId {
                releaseFlightOwner(ownerId, flightId: ownedFlightId, cancelIfUnobserved: false)
            }
        } catch {
            if let ownedFlightId {
                releaseFlightOwner(ownerId, flightId: ownedFlightId, cancelIfUnobserved: true)
            }
            throw error
        }
    }

    func frame(
        at frameIndex: UInt64,
        prefetchThrough upperBound: UInt64,
        prioritizingFirstResponse: Bool = false
    ) async throws -> Data {
        guard frameIndex < frameCount,
              upperBound >= frameIndex,
              upperBound < frameCount,
              upperBound - frameIndex < UInt64(Self.maximumFrameBatch) else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }
        try Task.checkCancellation()
        if let cached = cachedFrame(frameIndex) { return cached }
        return try await waitForFlight(
            containing: frameIndex,
            preferredUpperBound: upperBound,
            prioritizingFirstResponse: prioritizingFirstResponse
        )
    }

    func removeAllCachedFrames() {
        cache.removeAll()
        cacheCost = 0
        cacheGeneration &+= 1
    }

    func invalidate() {
        let activeTasks = flights.values.compactMap(\.task)
        let waiters = flights.values.flatMap { $0.waiters.values.map(\.continuation) }
        flights.removeAll()
        flightIdByFrame.removeAll()
        priorityFlightIdByFrame.removeAll()
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
        preferredUpperBound: UInt64,
        prioritizingFirstResponse: Bool
    ) async throws -> Data {
        let waiterId = UUID()
        let cancellation = E2eeRangeFrameWaiterCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let flightId = registerWaiter(
                    waiterId: waiterId,
                    continuation: continuation,
                    frameIndex: frameIndex,
                    preferredUpperBound: preferredUpperBound,
                    prioritizingFirstResponse: prioritizingFirstResponse
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
        continuation: CheckedContinuation<Data, Error>,
        frameIndex: UInt64,
        preferredUpperBound: UInt64,
        prioritizingFirstResponse: Bool
    ) -> UUID {
        let flightId = findOrStartFlight(
            containing: frameIndex,
            preferredUpperBound: preferredUpperBound,
            prioritizingFirstResponse: prioritizingFirstResponse
        )
        guard var flight = flights[flightId] else { return flightId }
        flight.waiters[waiterId] = FrameWaiter(
            frameIndex: frameIndex,
            continuation: continuation
        )
        flights[flightId] = flight
        return flightId
    }

    private func acquireFlightOwner(
        ownerId: UUID,
        containing frameIndex: UInt64,
        preferredUpperBound: UInt64,
        prioritizingFirstResponse: Bool
    ) -> UUID {
        let flightId = findOrStartFlight(
            containing: frameIndex,
            preferredUpperBound: preferredUpperBound,
            prioritizingFirstResponse: prioritizingFirstResponse
        )
        if var flight = flights[flightId] {
            flight.owners.insert(ownerId)
            flights[flightId] = flight
        }
        return flightId
    }

    private func findOrStartFlight(
        containing frameIndex: UInt64,
        preferredUpperBound: UInt64,
        prioritizingFirstResponse: Bool
    ) -> UUID {
        if prioritizingFirstResponse,
           let priorityId = priorityFlightIdByFrame[frameIndex],
           flights[priorityId] != nil {
            return priorityId
        }
        if let existingId = flightIdByFrame[frameIndex],
           let existing = flights[existingId] {
            if !prioritizingFirstResponse || existing.usesPriorityTransport {
                return existingId
            }
        }

        let bypassesLowerPriorityFlight = prioritizingFirstResponse
            && flightIdByFrame[frameIndex] != nil
        if bypassesLowerPriorityFlight { telemetry.recordPriorityBypass() }
        var upperBound = frameIndex
        while !bypassesLowerPriorityFlight, upperBound < preferredUpperBound {
            let candidate = upperBound + 1
            guard cache[candidate] == nil,
                  flightIdByFrame[candidate] == nil else { break }
            upperBound = candidate
        }
        return startFlight(
            frameRange: frameIndex...upperBound,
            isPriorityBypass: bypassesLowerPriorityFlight,
            usesPriorityTransport: prioritizingFirstResponse
        )
    }

    private func startFlight(
        frameRange: ClosedRange<UInt64>,
        isPriorityBypass: Bool,
        usesPriorityTransport: Bool
    ) -> UUID {
        let flightId = UUID()
        flights[flightId] = Flight(
            id: flightId,
            frameRange: frameRange,
            cacheGeneration: cacheGeneration,
            usesPriorityTransport: usesPriorityTransport,
            task: nil,
            waiters: [:],
            owners: []
        )
        if isPriorityBypass {
            priorityFlightIdByFrame[frameRange.lowerBound] = flightId
        } else {
            for index in frameRange { flightIdByFrame[index] = flightId }
        }

        let asset = asset
        let key = contentKey
        let noncePrefix = noncePrefix
        let streamer = streamer
        let task = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                let cipherRange = try Self.ciphertextRange(for: frameRange, asset: asset)
                let decoder = try FrameStreamDecoder(
                    frameRange: frameRange,
                    asset: asset,
                    contentKey: key,
                    noncePrefix: noncePrefix
                )
                try await streamer(cipherRange, usesPriorityTransport) { [weak self] chunk in
                    let frames = try await decoder.consume(chunk)
                    for (frameIndex, plaintext) in frames {
                        await self?.publishFrame(
                            plaintext,
                            frameIndex: frameIndex,
                            flightId: flightId
                        )
                    }
                }
                try await decoder.finish()
                result = .success(())
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
              let waiter = flight.waiters.removeValue(forKey: waiterId) else {
            return
        }
        waiter.continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty, flight.owners.isEmpty {
            flight.task?.cancel()
            removeFlight(flight)
        } else {
            flights[flightId] = flight
        }
    }

    private func releaseFlightOwner(
        _ ownerId: UUID,
        flightId: UUID,
        cancelIfUnobserved: Bool
    ) {
        guard var flight = flights[flightId] else { return }
        flight.owners.remove(ownerId)
        if cancelIfUnobserved, flight.owners.isEmpty, flight.waiters.isEmpty {
            flight.task?.cancel()
            removeFlight(flight)
        } else {
            flights[flightId] = flight
        }
    }

    private func publishFrame(_ data: Data, frameIndex: UInt64, flightId: UUID) {
        guard var flight = flights[flightId] else { return }
        if flight.cacheGeneration == cacheGeneration {
            insertCachedFrame(data, frameIndex: frameIndex)
        }
        if flightIdByFrame[frameIndex] == flightId { flightIdByFrame[frameIndex] = nil }
        if priorityFlightIdByFrame[frameIndex] == flightId {
            priorityFlightIdByFrame[frameIndex] = nil
        }
        let matchingWaiterIds = flight.waiters.compactMap { entry in
            entry.value.frameIndex == frameIndex ? entry.key : nil
        }
        let continuations = matchingWaiterIds.compactMap { waiterId in
            flight.waiters.removeValue(forKey: waiterId)?.continuation
        }
        flights[flightId] = flight
        continuations.forEach { $0.resume(returning: data) }
    }

    private func completeFlight(_ flightId: UUID, result: Result<Void, Error>) {
        guard let flight = flights[flightId] else { return }
        removeFlight(flight)
        switch result {
        case .success:
            flight.waiters.values.forEach {
                $0.continuation.resume(throwing: E2eeRangeStreamingResourceError.invalidFrame)
            }
        case let .failure(error):
            flight.waiters.values.forEach { $0.continuation.resume(throwing: error) }
        }
    }

    private func removeFlight(_ flight: Flight) {
        flights[flight.id] = nil
        for frameIndex in flight.frameRange where flightIdByFrame[frameIndex] == flight.id {
            flightIdByFrame[frameIndex] = nil
        }
        for frameIndex in flight.frameRange where priorityFlightIdByFrame[frameIndex] == flight.id {
            priorityFlightIdByFrame[frameIndex] = nil
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
    private let mediaDescription: E2eeRangeMediaDescription
    private let reader: E2eeRangeCiphertextReader
    private let priorityReader: E2eeRangeCiphertextReader
    private let grantStore: E2eeRangeStreamingGrantStore
    private let frameStore: E2eeRangePlaintextFrameStore
    private let fallback: E2eeRangeFallbackFile
    private let telemetry: E2eeRangeStreamingTelemetry
    private let loadingRequestCancellationHandler: @Sendable () -> Void
    private let loadingRequestObserver: (AVAssetResourceLoadingRequest) -> Void
    private let invalidationCompletionHandler: @Sendable () -> Void
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
        loadingRequestObserver: @escaping (AVAssetResourceLoadingRequest) -> Void = { _ in },
        invalidationCompletionHandler: @escaping @Sendable () -> Void = {},
        attachmentMimeType: String? = nil,
        attachmentFileName: String? = nil
    ) throws {
        let mediaDescription = E2eeRangeMediaDescription.resolve(
            asset: asset,
            attachmentMimeType: attachmentMimeType,
            attachmentFileName: attachmentFileName
        )
        guard let streamURL = URL(
            string: "\(Self.scheme)://asset/\(UUID().uuidString).\(mediaDescription.fileExtension)"
        ) else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        self.asset = asset
        self.streamURL = streamURL
        self.mediaDescription = mediaDescription
        self.telemetry = telemetry
        telemetry.recordMediaTypeSource(mediaDescription.source)
        self.loadingRequestCancellationHandler = loadingRequestCancellationHandler
        self.loadingRequestObserver = loadingRequestObserver
        self.invalidationCompletionHandler = invalidationCompletionHandler
        let continuationConfiguration = Self.copySessionConfiguration(sessionConfiguration)
        let priorityConfiguration = Self.copySessionConfiguration(sessionConfiguration)
        priorityConfiguration.networkServiceType = .responsiveData
        let grantStore = E2eeRangeStreamingGrantStore(
            grantProvider: grantProvider,
            eventHandler: { telemetry.recordGrantEvent($0) }
        )
        self.grantStore = grantStore
        let reader = E2eeRangeCiphertextReader(
            grantStore: grantStore,
            sessionConfiguration: continuationConfiguration,
            telemetry: telemetry
        )
        let priorityReader = E2eeRangeCiphertextReader(
            grantStore: grantStore,
            sessionConfiguration: priorityConfiguration,
            telemetry: telemetry,
            transportClass: .priority,
            taskPriority: URLSessionTask.highPriority
        )
        self.reader = reader
        self.priorityReader = priorityReader
        frameStore = try E2eeRangePlaintextFrameStore(
            asset: asset,
            cacheCostLimit: cacheCostLimit,
            telemetry: telemetry,
            streamingFetcher: { range, usesPriorityTransport, consume in
                let selectedReader = usesPriorityTransport ? priorityReader : reader
                try await selectedReader.stream(
                    assetId: asset.assetId,
                    range: range,
                    totalCiphertextSize: asset.cipherSize,
                    consume: consume
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
            telemetry.recordActiveLoadingRequestCount(activeLoadingRequests.count)
            return true
        }
        guard accepted else { return false }

        let task = Task { [weak self, loadingRequest] in
            guard await startGate.wait(), let self else { return }
            defer { self.removeTask(for: key, token: token) }
            do {
                try await self.fulfill(loadingRequest, startedAt: startedAt)
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
        // Stop byte delivery synchronously at the viewer boundary. The remaining actor cleanup
        // runs independently below, but no Range task may survive long enough to answer after the
        // playback lease has been released.
        priorityReader.invalidateTransport()
        reader.invalidateTransport()
        log.info("[E2EE_RANGE_PLAYBACK] state=closing", subsystems: .mls)
#if canImport(UIKit)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
        }
#endif
        let grantStore = grantStore
        let frameStore = frameStore
        let fallback = fallback
        let assetId = asset.assetId
        let telemetry = telemetry
        let invalidationCompletionHandler = invalidationCompletionHandler
        // Viewer release can originate from a cancelled UI/resolver task. Cleanup must not inherit
        // that cancellation state, otherwise the proactive grant timer can outlive the preview.
        Task.detached(priority: .utility) {
            await grantStore.invalidateSession(for: assetId)
            await frameStore.invalidate()
            await fallback.release()
            log.info(
                E2eeRangeStreamingTelemetry.summary(telemetry.snapshot()),
                subsystems: .mls
            )
            invalidationCompletionHandler()
        }
    }

    private static func copySessionConfiguration(
        _ configuration: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        (configuration.copy() as? URLSessionConfiguration) ?? configuration
    }

    private func removeTask(for key: ObjectIdentifier, token: UUID) {
        _ = lock.withLock {
            guard activeLoadingRequests[key]?.token == token else { return }
            activeLoadingRequests.removeValue(forKey: key)
        }
    }

    private func fulfill(
        _ request: AVAssetResourceLoadingRequest,
        startedAt: Date
    ) async throws {
        guard let plaintextSize = asset.plaintextSize else {
            throw E2eeRangeStreamingResourceError.invalidManifest
        }
        populateContentInformation(request.contentInformationRequest, plaintextSize: plaintextSize)
        guard let dataRequest = request.dataRequest else { return }
        guard let range = requestedRange(dataRequest, plaintextSize: plaintextSize) else { return }
        let requestsAllDataToEnd = dataRequest.requestsAllDataToEndOfResource
        let region = telemetry.recordLoadingRequestShape(
            range: range,
            plaintextSize: plaintextSize,
            frameSize: UInt64(asset.frameSize),
            requestsAllDataToEnd: requestsAllDataToEnd
        )
        try await streamPlaintext(range: range, to: dataRequest) { [telemetry] in
            telemetry.recordFirstResponse(
                latency: Date().timeIntervalSince(startedAt),
                region: region,
                requestsAllDataToEnd: requestsAllDataToEnd
            )
        }
    }

    private func streamPlaintext(
        range: Range<UInt64>,
        to request: AVAssetResourceLoadingDataRequest,
        onFirstResponse: () -> Void
    ) async throws {
        guard !range.isEmpty else { return }
        let frameSize = UInt64(asset.frameSize)
        let firstFrame = range.lowerBound / frameSize
        let lastFrame = (range.upperBound - 1) / frameSize
        var batchStart = firstFrame
        var hasResponded = false
        while batchStart <= lastFrame {
            try Task.checkCancellation()
            let batch = await frameStore.batch(
                firstFrame: batchStart,
                lastFrame: lastFrame,
                prioritizingFirstResponse: !hasResponded
            )
            try await frameStore.consumeFrames(
                in: batch,
                prioritizingFirstResponse: !hasResponded
            ) { frameIndex, plaintext in
                try Task.checkCancellation()
                let framePlainStart = frameIndex * frameSize
                let overlapStart = max(range.lowerBound, framePlainStart)
                let overlapEnd = min(range.upperBound, framePlainStart + UInt64(plaintext.count))
                if overlapStart < overlapEnd {
                    let lower = Int(overlapStart - framePlainStart)
                    let upper = Int(overlapEnd - framePlainStart)
                    try Task.checkCancellation()
                    if !hasResponded {
                        hasResponded = true
                        onFirstResponse()
                    }
                    request.respond(with: plaintext.subdata(in: lower..<upper))
                }
            }
            batchStart = batch.upperBound + 1
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
        let allowed = information.allowedContentTypes
        if allowed == nil
            || allowed?.isEmpty == true
            || allowed?.contains(mediaDescription.contentTypeIdentifier) == true {
            information.contentType = mediaDescription.contentTypeIdentifier
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
