//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import AVFoundation
import Foundation
import XCTest

final class E2eeRangeStreamingResourceLoaderTests: XCTestCase {
    override func tearDown() {
        RangeStreamingURLProtocol.removeHandler()
        RangeStreamingBlockingURLProtocol.reset()
        super.tearDown()
    }

    func testLoadingRequestStartGateStartsRegisteredRequest() async {
        let gate = E2eeRangeLoadingRequestStartGate()
        let waiter = Task { await gate.wait() }

        gate.resolve(true)

        let shouldStart = await waiter.value
        XCTAssertTrue(shouldStart)
    }

    func testLoadingRequestStartGateKeepsFirstCancellationResolution() async {
        let gate = E2eeRangeLoadingRequestStartGate()
        gate.resolve(false)
        gate.resolve(true)

        let shouldStart = await gate.wait()
        XCTAssertFalse(shouldStart)
    }

    func testAVAssetCancellationCancelsUnderlyingCiphertextRequest() async throws {
        let fixture = try makeFixture(
            plaintext: makePCMWave(duration: 1),
            frameSize: 128,
            mimeType: "audio/wav"
        )
        let grantURL = try XCTUnwrap(URL(string: "https://range.test/cancel"))
        let requestCapture = RangeStreamingLoadingRequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStreamingBlockingURLProtocol.self]
        let loader = try E2eeRangeStreamingResourceLoader(
            asset: fixture.asset,
            grantProvider: { assetId in
                E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: grantURL,
                    expiresAt: Date().addingTimeInterval(300)
                )
            },
            fallbackProvider: {
                E2eeAttachmentOriginalLease(localURL: fixture.plaintextURL, releaseHandler: {})
            },
            sessionConfiguration: configuration,
            loadingRequestCancellationHandler: {
                RangeStreamingBlockingURLProtocol.state.markCancelled()
            },
            loadingRequestObserver: { request in
                requestCapture.store(request)
            }
        )
        let asset = loader.makeAsset()
        asset.resourceLoader.setDelegate(
            loader,
            queue: DispatchQueue(label: "network.ermis.tests.range-cancellation")
        )

        let loadTask = Task { try await asset.load(.duration) }
        try await waitUntil { requestCapture.request != nil }
        let request = try XCTUnwrap(requestCapture.request)
        loader.resourceLoader(asset.resourceLoader, didCancel: request)
        try await waitUntil { RangeStreamingBlockingURLProtocol.state.cancelled }
        asset.cancelLoading()
        loadTask.cancel()
        _ = try? await loadTask.value

        XCTAssertTrue(RangeStreamingBlockingURLProtocol.state.cancelled)
        loader.invalidate()
    }

    func testAVAssetPartialRangeFailureContinuesFromFallbackWithoutDuplicateBytes() async throws {
        let fixture = try makeFixture(
            plaintext: makePCMWave(duration: 1),
            frameSize: 128,
            mimeType: "audio/wav"
        )
        let requestCount = RangeStreamingCounter()
        let telemetry = E2eeRangeStreamingTelemetry()
        RangeStreamingURLProtocol.installHandler { request in
            let count = requestCount.increment()
            guard let range = Self.requestedByteRange(request) else {
                return .init(statusCode: 400, headers: [:], data: Data())
            }
            let exact = try? fixture.ciphertext.slice(range)
            let responseData: Data
            if count == 2, let exact, !exact.isEmpty {
                responseData = Data(exact.dropLast())
            } else {
                responseData = exact ?? Data()
            }
            return .init(
                statusCode: 206,
                headers: [
                    "Content-Length": String(responseData.count),
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fixture.ciphertext.count)"
                ],
                data: responseData
            )
        }
        let grantURL = try XCTUnwrap(URL(string: "https://range.test/partial-fallback"))
        let loader = try E2eeRangeStreamingResourceLoader(
            asset: fixture.asset,
            grantProvider: { assetId in
                E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: grantURL,
                    expiresAt: Date().addingTimeInterval(300)
                )
            },
            fallbackProvider: {
                E2eeAttachmentOriginalLease(localURL: fixture.plaintextURL, releaseHandler: {})
            },
            sessionConfiguration: rangeSessionConfiguration(),
            telemetry: telemetry
        )
        let asset = loader.makeAsset()
        asset.resourceLoader.setDelegate(
            loader,
            queue: DispatchQueue(label: "network.ermis.tests.range-partial-fallback")
        )

        let duration = try await asset.load(.duration)

        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
        XCTAssertGreaterThanOrEqual(requestCount.value, 2)
        XCTAssertEqual(telemetry.snapshot().lastFallbackReason, .responseContract)
        loader.invalidate()
    }

    func testCiphertextReaderRequiresExact206HeadersAndBytes() async throws {
        let bytes = Data((0..<100).map { UInt8($0) })
        RangeStreamingURLProtocol.installHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-19")
            return .init(
                statusCode: 206,
                headers: [
                    "Content-Length": "10",
                    "Content-Range": "bytes 10-19/100"
                ],
                data: bytes.subdata(in: 10..<20)
            )
        }
        let reader = try makeReader()

        let result = try await reader.read(
            assetId: "opaque-asset",
            range: 10..<20,
            totalCiphertextSize: 100
        )

        XCTAssertEqual(result, bytes.subdata(in: 10..<20))
        await reader.invalidate(assetId: "opaque-asset")
    }

    func testCiphertextReaderRejects200AndMismatchedContentRange() async throws {
        let readerFor200 = try makeReader()
        RangeStreamingURLProtocol.installHandler { _ in
            .init(
                statusCode: 200,
                headers: ["Content-Length": "10"],
                data: Data(repeating: 1, count: 10)
            )
        }
        do {
            _ = try await readerFor200.read(
                assetId: "opaque-asset",
                range: 10..<20,
                totalCiphertextSize: 100
            )
            XCTFail("A 200 response to Range must fail closed")
        } catch let error as E2eeRangeStreamingResourceError {
            XCTAssertEqual(error, .invalidContentRange)
        }
        await readerFor200.invalidate(assetId: "opaque-asset")

        let readerForMismatch = try makeReader()
        RangeStreamingURLProtocol.installHandler { _ in
            .init(
                statusCode: 206,
                headers: [
                    "Content-Length": "10",
                    "Content-Range": "bytes 11-20/100"
                ],
                data: Data(repeating: 2, count: 10)
            )
        }
        do {
            _ = try await readerForMismatch.read(
                assetId: "opaque-asset",
                range: 10..<20,
                totalCiphertextSize: 100
            )
            XCTFail("A shifted Content-Range must fail closed")
        } catch let error as E2eeRangeStreamingResourceError {
            XCTAssertEqual(error, .invalidContentRange)
        }
        await readerForMismatch.invalidate(assetId: "opaque-asset")
    }

    func testCiphertextReaderRenewsOnceAfterUnauthorized() async throws {
        let firstURL = try XCTUnwrap(URL(string: "https://range.test/first"))
        let secondURL = try XCTUnwrap(URL(string: "https://range.test/second"))
        let providerCalls = RangeStreamingCounter()
        let requestCalls = RangeStreamingCounter()
        let telemetry = E2eeRangeStreamingTelemetry()
        let now = Date()
        let grantStore = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                let generation = providerCalls.increment()
                return E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: generation == 1 ? firstURL : secondURL,
                    expiresAt: now.addingTimeInterval(300),
                    issuedAt: now
                )
            },
            clock: { now },
            sleepUntil: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) },
            eventHandler: { telemetry.recordGrantEvent($0) }
        )
        RangeStreamingURLProtocol.installHandler { request in
            _ = requestCalls.increment()
            if request.url == firstURL {
                return .init(statusCode: 401, headers: [:], data: Data())
            }
            return .init(
                statusCode: 206,
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 4-7/20"
                ],
                data: Data([4, 5, 6, 7])
            )
        }
        let reader = E2eeRangeCiphertextReader(
            grantStore: grantStore,
            sessionConfiguration: rangeSessionConfiguration(),
            telemetry: telemetry
        )

        let result = try await reader.read(
            assetId: "opaque-asset",
            range: 4..<8,
            totalCiphertextSize: 20
        )

        XCTAssertEqual(result, Data([4, 5, 6, 7]))
        XCTAssertEqual(providerCalls.value, 2)
        XCTAssertEqual(requestCalls.value, 2)
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.initialGrantRequests, 1)
        XCTAssertEqual(snapshot.grantRenewalRequests, 1)
        XCTAssertEqual(snapshot.rangeRequests, 2)
        XCTAssertEqual(snapshot.ciphertextBytes, 4)
        await reader.invalidate(assetId: "opaque-asset")
    }

    func testCiphertextReaderFailsAfterSecondUnauthorizedWithoutThirdAttempt() async throws {
        let providerCalls = RangeStreamingCounter()
        let requestCalls = RangeStreamingCounter()
        let grantBaseURL = try XCTUnwrap(URL(string: "https://range.test"))
        let now = Date()
        let grantStore = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                let generation = providerCalls.increment()
                return E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: grantBaseURL.appendingPathComponent("grant-\(generation)"),
                    expiresAt: now.addingTimeInterval(300),
                    issuedAt: now
                )
            },
            clock: { now },
            sleepUntil: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        )
        RangeStreamingURLProtocol.installHandler { _ in
            _ = requestCalls.increment()
            return .init(statusCode: 403, headers: [:], data: Data())
        }
        let reader = E2eeRangeCiphertextReader(
            grantStore: grantStore,
            sessionConfiguration: rangeSessionConfiguration()
        )

        do {
            _ = try await reader.read(
                assetId: "opaque-asset",
                range: 4..<8,
                totalCiphertextSize: 20
            )
            XCTFail("A second authorization failure must fail closed")
        } catch let error as E2eeRangeStreamingResourceError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(providerCalls.value, 2)
        XCTAssertEqual(requestCalls.value, 2)
        await reader.invalidate(assetId: "opaque-asset")
    }

    func testFrameStoreCachesVerifiedFramesWithinByteBudget() async throws {
        let fixture = try makeFixture(frameCount: 6, frameSize: 32)
        let fetches = RangeStreamingCounter()
        let telemetry = E2eeRangeStreamingTelemetry()
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            cacheCostLimit: 64,
            telemetry: telemetry,
            fetcher: { range in
                _ = fetches.increment()
                return try fixture.ciphertext.slice(range)
            }
        )

        let first = try await store.frames(in: 0...1)
        let cached = try await store.frames(in: 0...0)
        let second = try await store.frames(in: 2...3)

        XCTAssertEqual(first[0], fixture.plaintext.subdata(in: 0..<32))
        XCTAssertEqual(cached[0], fixture.plaintext.subdata(in: 0..<32))
        XCTAssertEqual(second[3], fixture.plaintext.subdata(in: 96..<128))
        XCTAssertEqual(fetches.value, 2)
        let cachedByteCount = await store.cachedByteCount
        let cachedFrameCount = await store.cachedFrameCount
        XCTAssertLessThanOrEqual(cachedByteCount, 64)
        XCTAssertLessThanOrEqual(cachedFrameCount, 2)
        XCTAssertGreaterThanOrEqual(telemetry.snapshot().cacheHitBytes, 32)

        await store.removeAllCachedFrames()
        let clearedByteCount = await store.cachedByteCount
        let clearedFrameCount = await store.cachedFrameCount
        XCTAssertEqual(clearedByteCount, 0)
        XCTAssertEqual(clearedFrameCount, 0)
        await store.invalidate()
    }

    func testOverlappingFrameRequestsShareOneCiphertextFlight() async throws {
        let fixture = try makeFixture(frameCount: 8, frameSize: 32)
        let fetches = RangeStreamingCounter()
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { range in
                _ = fetches.increment()
                try await Task.sleep(nanoseconds: 40_000_000)
                return try fixture.ciphertext.slice(range)
            }
        )

        async let first = store.frames(in: 0...3)
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second = store.frames(in: 1...2)
        let results = try await (first, second)

        XCTAssertEqual(results.0[1], fixture.plaintext.subdata(in: 32..<64))
        XCTAssertEqual(results.1[2], fixture.plaintext.subdata(in: 64..<96))
        XCTAssertEqual(fetches.value, 1)
        let activeFlightCount = await store.activeFlightCount
        XCTAssertEqual(activeFlightCount, 0)
        await store.invalidate()
    }

    func testPartiallyOverlappingRequestsNeverFetchTheSameFrameTwice() async throws {
        let fixture = try makeFixture(frameCount: 8, frameSize: 32)
        let gate = RangeStreamingFetchGate()
        let ranges = RangeStreamingRangeRecorder()
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { range in
                ranges.append(range)
                if ranges.count == 1 {
                    await gate.waitForRelease()
                    try Task.checkCancellation()
                }
                return try fixture.ciphertext.slice(range)
            }
        )

        let first = Task { try await store.frames(in: 0...3) }
        await gate.waitUntilStarted()
        let second = Task { try await store.frames(in: 1...4) }
        try await waitUntilAsync { await store.activeWaiterCount == 2 }
        await gate.release()
        let results = try await (first.value, second.value)

        XCTAssertEqual(results.0.count, 4)
        XCTAssertEqual(results.1.count, 4)
        XCTAssertEqual(ranges.values.count, 2)
        let recorded = ranges.values.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertLessThanOrEqual(recorded[0].upperBound, recorded[1].lowerBound)
        await store.invalidate()
    }

    func testCancellingOneOfTwoWaitersKeepsSharedFetchAlive() async throws {
        let fixture = try makeFixture(frameCount: 8, frameSize: 32)
        let gate = RangeStreamingFetchGate()
        let fetches = RangeStreamingCounter()
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { range in
                _ = fetches.increment()
                await gate.waitForRelease()
                try Task.checkCancellation()
                return try fixture.ciphertext.slice(range)
            }
        )

        let cancelled = Task { try await store.frames(in: 0...3) }
        await gate.waitUntilStarted()
        let survivor = Task { try await store.frames(in: 1...2) }
        try await waitUntilAsync { await store.activeWaiterCount == 2 }

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("The cancelled waiter must fail independently")
        } catch is CancellationError {
            // Expected.
        }
        let activeFlightCount = await store.activeFlightCount
        let activeWaiterCount = await store.activeWaiterCount
        XCTAssertEqual(activeFlightCount, 1)
        XCTAssertEqual(activeWaiterCount, 1)

        await gate.release()
        let result = try await survivor.value
        XCTAssertEqual(result[1], fixture.plaintext.subdata(in: 32..<64))
        XCTAssertEqual(fetches.value, 1)
        await store.invalidate()
    }

    func testCancellingOnlyWaiterCancelsFetchAndRemovesFlight() async throws {
        let fixture = try makeFixture(frameCount: 8, frameSize: 32)
        let state = RangeStreamingCancellationState()
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { _ in
                state.markStarted()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Data()
                } catch {
                    state.markCancelled()
                    throw error
                }
            }
        )
        let task = Task { try await store.frames(in: 0...7) }
        try await waitUntil { state.started }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled frame waiter must not complete successfully")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { state.cancelled }
        let activeFlightCount = await store.activeFlightCount
        XCTAssertEqual(activeFlightCount, 0)
        await store.invalidate()
    }

    func testCacheClearDuringActiveFlightPreventsLatePlaintextRepopulation() async throws {
        let fixture = try makeFixture(frameCount: 4, frameSize: 32)
        let gate = RangeStreamingFetchGate()
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { range in
                await gate.waitForRelease()
                try Task.checkCancellation()
                return try fixture.ciphertext.slice(range)
            }
        )

        let task = Task { try await store.frames(in: 0...1) }
        await gate.waitUntilStarted()
        await store.removeAllCachedFrames()
        await gate.release()
        let result = try await task.value

        XCTAssertEqual(result.count, 2)
        let cachedByteCount = await store.cachedByteCount
        let cachedFrameCount = await store.cachedFrameCount
        XCTAssertEqual(cachedByteCount, 0)
        XCTAssertEqual(cachedFrameCount, 0)
        await store.invalidate()
    }

    func testSequentialDetectionPrefetchesAtMostEightFramesButFirstRandomSeekIsExact() async throws {
        let fixture = try makeFixture(frameCount: 12, frameSize: 32)
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { range in try fixture.ciphertext.slice(range) }
        )

        let first = await store.firstBatch(
            for: 128..<132,
            firstFrame: 4,
            lastFrame: 4
        )
        let sequential = await store.firstBatch(
            for: 132..<136,
            firstFrame: 4,
            lastFrame: 4
        )
        let distantRandom = await store.firstBatch(
            for: 320..<324,
            firstFrame: 10,
            lastFrame: 10
        )

        XCTAssertEqual(first, 4...4)
        XCTAssertEqual(sequential, 4...11)
        XCTAssertEqual(sequential.count, E2eeRangePlaintextFrameStore.maximumFrameBatch)
        XCTAssertEqual(distantRandom, 10...10)
        await store.invalidate()
    }

    func testCorruptFrameFailsBeforePlaintextCanEnterCache() async throws {
        let fixture = try makeFixture(frameCount: 2, frameSize: 32)
        var mutableCiphertext = fixture.ciphertext
        mutableCiphertext[mutableCiphertext.count - 1] ^= 0xff
        let corrupted = mutableCiphertext
        let store = try E2eeRangePlaintextFrameStore(
            asset: fixture.asset,
            fetcher: { range in try corrupted.slice(range) }
        )

        do {
            _ = try await store.frames(in: 1...1)
            XCTFail("A bad AES-GCM tag must fail closed")
        } catch let error as E2eeRangeStreamingResourceError {
            XCTAssertEqual(error, .invalidFrame)
        }
        let cachedFrameCount = await store.cachedFrameCount
        XCTAssertEqual(cachedFrameCount, 0)
        await store.invalidate()
    }

    func testTelemetrySummaryContainsOnlyFixedCountersAndCategories() {
        let telemetry = E2eeRangeStreamingTelemetry()
        telemetry.recordGrantEvent(.initialRequest)
        telemetry.recordGrantEvent(.renewalRequest)
        telemetry.recordRangeRequest()
        telemetry.recordCiphertextBytes(128)
        telemetry.recordCacheHit(bytes: 64)
        telemetry.recordLoadingRequest(latency: 0.125)
        telemetry.recordFallback(.responseContract)

        let summary = E2eeRangeStreamingTelemetry.summary(telemetry.snapshot())

        XCTAssertTrue(summary.contains("range_requests=1"))
        XCTAssertTrue(summary.contains("ciphertext_bytes=128"))
        XCTAssertTrue(summary.contains("fallback_reason=responseContract"))
        for forbidden in [
            "http://", "https://", "attachment_id", "message_id", "channel_id",
            "user_id", "grant_url", "authorization", "/private/", "content_key"
        ] {
            XCTAssertFalse(summary.lowercased().contains(forbidden))
        }
    }

    private func makeReader() throws -> E2eeRangeCiphertextReader {
        let url = try XCTUnwrap(URL(string: "https://range.test/object"))
        let now = Date()
        let store = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: url,
                    expiresAt: now.addingTimeInterval(300),
                    issuedAt: now
                )
            },
            clock: { now },
            sleepUntil: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        )
        return E2eeRangeCiphertextReader(
            grantStore: store,
            sessionConfiguration: rangeSessionConfiguration()
        )
    }

    private func rangeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStreamingURLProtocol.self]
        return configuration
    }

    private func makeFixture(frameCount: Int, frameSize: Int) throws -> RangeStreamingFixture {
        try makeFixture(
            plaintext: Data((0..<(frameCount * frameSize)).map { UInt8(truncatingIfNeeded: $0) }),
            frameSize: frameSize,
            mimeType: nil
        )
    }

    private func makeFixture(
        plaintext: Data,
        frameSize: Int,
        mimeType: String?
    ) throws -> RangeStreamingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2ee-range-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let plaintextURL = directory.appendingPathComponent("plain.bin")
        let ciphertextURL = directory.appendingPathComponent("cipher.bin")
        try plaintext.write(to: plaintextURL, options: .atomic)
        let contentKey = Data((0..<E2eeAttachmentFrameCryptoV1.keySize).map { UInt8($0) })
        let noncePrefix = Data((0..<E2eeAttachmentFrameCryptoV1.noncePrefixSize).map {
            UInt8(0xa0 + $0)
        })
        let result = try E2eeAttachmentFrameCryptoV1.encryptFile(
            at: plaintextURL,
            to: ciphertextURL,
            contentKey: contentKey,
            noncePrefix: noncePrefix,
            frameSize: frameSize
        )
        let asset = E2eeAttachmentManifestAssetV1(
            assetId: UUID().uuidString,
            kind: .original,
            cipherSize: result.ciphertextSize,
            cipherSha256: result.ciphertextSha256,
            frameSize: result.frameSize,
            contentKey: contentKey.base64EncodedString(),
            noncePrefix: noncePrefix.base64EncodedString(),
            plaintextSize: result.plaintextSize,
            plaintextSha256: result.plaintextSha256,
            display: mimeType.map { ["mime_type": .string($0)] }
        )
        return RangeStreamingFixture(
            plaintext: plaintext,
            plaintextURL: plaintextURL,
            ciphertext: try Data(contentsOf: ciphertextURL),
            asset: asset
        )
    }

    private func makePCMWave(duration: TimeInterval) -> Data {
        let sampleRate: UInt32 = 8_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        let dataSize = UInt32(sampleCount * Int(channelCount) * Int(bitsPerSample / 8))
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private static func requestedByteRange(_ request: URLRequest) -> Range<UInt64>? {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes=") else { return nil }
        let components = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        guard components.count == 2,
              let lower = UInt64(components[0]),
              let upper = UInt64(components[1]),
              lower <= upper else { return nil }
        return lower..<(upper + 1)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for async range state")
    }

    private func waitUntilAsync(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for async range state")
    }
}

private struct RangeStreamingFixture: Sendable {
    let plaintext: Data
    let plaintextURL: URL
    let ciphertext: Data
    let asset: E2eeAttachmentManifestAssetV1
}

private extension Data {
    func slice(_ range: Range<UInt64>) throws -> Data {
        guard range.lowerBound <= UInt64(Int.max),
              range.upperBound <= UInt64(Int.max),
              range.upperBound <= UInt64(count) else {
            throw E2eeRangeStreamingResourceError.invalidRange
        }
        return subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii) ?? Data())
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private final class RangeStreamingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class RangeStreamingCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    func markStarted() {
        lock.lock()
        didStart = true
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        didCancel = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        didStart = false
        didCancel = false
        lock.unlock()
    }
}

private actor RangeStreamingFetchGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        if !started {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class RangeStreamingRangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<UInt64>] = []

    var values: [Range<UInt64>] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ranges.count
    }

    func append(_ range: Range<UInt64>) {
        lock.lock()
        ranges.append(range)
        lock.unlock()
    }
}

private final class RangeStreamingLoadingRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: AVAssetResourceLoadingRequest?

    var request: AVAssetResourceLoadingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func store(_ request: AVAssetResourceLoadingRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class RangeStreamingURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    typealias Handler = @Sendable (URLRequest) -> Response

    private static let handlerLock = NSLock()
    private static var handler: Handler?

    static func installHandler(_ handler: @escaping Handler) {
        handlerLock.lock()
        self.handler = handler
        handlerLock.unlock()
    }

    static func removeHandler() {
        handlerLock.lock()
        handler = nil
        handlerLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handlerLock.lock()
        let handler = Self.handler
        Self.handlerLock.unlock()
        guard let handler,
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RangeStreamingBlockingURLProtocol: URLProtocol {
    static let state = RangeStreamingCancellationState()

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.markStarted()
    }

    override func stopLoading() {
        Self.state.markCancelled()
    }
}
