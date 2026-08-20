//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import XCTest

final class E2eeRangeStreamingGrantStoreTests: XCTestCase {
    private actor Counter {
        var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    func testRenewalLeadUsesServerTTLAndNeverExceedsHalf() {
        XCTAssertEqual(E2eeRangeStreamingGrant.renewalLead(for: 600), 60)
        XCTAssertEqual(E2eeRangeStreamingGrant.renewalLead(for: 200), 40)
        XCTAssertEqual(E2eeRangeStreamingGrant.renewalLead(for: 60), 30)
        XCTAssertEqual(E2eeRangeStreamingGrant.renewalLead(for: 10), 5)
        XCTAssertEqual(E2eeRangeStreamingGrant.renewalLead(for: -1), 0)
    }

    func testRangeStreamingDefaultsOnWhenProcessOverrideIsAbsent() {
        XCTAssertTrue(E2eeRangeStreamingFeatureFlag.isEnabled(environment: [:]))
    }

    func testRangeStreamingProcessOverridePreservesOptInAndProvidesKillSwitch() {
        XCTAssertTrue(
            E2eeRangeStreamingFeatureFlag.isEnabled(
                environment: [E2eeRangeStreamingFeatureFlag.environmentKey: "1"]
            )
        )
        XCTAssertFalse(
            E2eeRangeStreamingFeatureFlag.isEnabled(
                environment: [E2eeRangeStreamingFeatureFlag.environmentKey: "0"]
            )
        )
        XCTAssertFalse(
            E2eeRangeStreamingFeatureFlag.isEnabled(
                environment: [E2eeRangeStreamingFeatureFlag.environmentKey: "invalid"]
            )
        )
    }

    func testPlaybackPolicyUsesRangeForEveryOpaqueVideoWithoutASizeThreshold() {
        XCTAssertTrue(
            E2eeVideoPlaybackPolicy.usesRangeStreaming(
                isOpaqueE2eeVideo: true,
                clientEnabled: true,
                processEnabled: true
            )
        )
        XCTAssertFalse(
            E2eeVideoPlaybackPolicy.usesRangeStreaming(
                isOpaqueE2eeVideo: false,
                clientEnabled: true,
                processEnabled: true
            )
        )
        XCTAssertFalse(
            E2eeVideoPlaybackPolicy.usesRangeStreaming(
                isOpaqueE2eeVideo: true,
                clientEnabled: false,
                processEnabled: true
            )
        )
        XCTAssertFalse(
            E2eeVideoPlaybackPolicy.usesRangeStreaming(
                isOpaqueE2eeVideo: true,
                clientEnabled: true,
                processEnabled: false
            )
        )
    }

    func testClientConfigDefaultsRangeStreamingOnAndAllowsRollback() {
        guard let baseURL = URL(string: "https://example.invalid") else {
            XCTFail("Expected a valid static test URL")
            return
        }
        var config = ErmisClientConfig(
            apiKeyString: "test-api-key",
            endpointEnviroment: .init(baseURL: baseURL)
        )

        XCTAssertTrue(config.isE2eeRangeStreamingEnabled)
        config.isE2eeRangeStreamingEnabled = false
        XCTAssertFalse(config.isE2eeRangeStreamingEnabled)
    }

    func testConcurrentCacheMissIsExactlySingleFlight() async throws {
        let calls = Counter()
        let now = Date()
        let store = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                _ = await calls.increment()
                try await Task.sleep(nanoseconds: 20_000_000)
                return Self.grant(assetId: assetId, issuedAt: now)
            },
            clock: { now },
            sleepUntil: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        )

        try await withThrowingTaskGroup(of: E2eeRangeStreamingGrant.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.grant(for: "asset") }
            }
            for try await grant in group {
                XCTAssertEqual(grant.assetId, "asset")
            }
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
        await store.invalidateAll()
    }

    func testProactiveTimerPerformsARealRefresh() async throws {
        let providerCalls = Counter()
        let sleeps = Counter()
        let now = Date()
        let store = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                _ = await providerCalls.increment()
                return Self.grant(assetId: assetId, issuedAt: now)
            },
            clock: { now },
            sleepUntil: { _ in
                let call = await sleeps.increment()
                if call == 1 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } else {
                    throw CancellationError()
                }
            }
        )

        _ = try await store.grant(for: "asset")
        try await Task.sleep(nanoseconds: 80_000_000)
        let providerCallCount = await providerCalls.value
        XCTAssertEqual(providerCallCount, 2)
        await store.invalidateAll()
    }

    func testConcurrentUnauthorizedRequestsShareOneRenewal() async throws {
        let calls = Counter()
        let now = Date()
        let store = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                let generation = await calls.increment()
                try await Task.sleep(nanoseconds: 10_000_000)
                return E2eeRangeStreamingGrant(
                    assetId: assetId,
                    grantURL: URL(string: "https://example.invalid/\(generation)")!,
                    expiresAt: now.addingTimeInterval(300),
                    issuedAt: now
                )
            },
            clock: { now },
            sleepUntil: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        )
        let stale = try await store.grant(for: "asset")

        async let first = store.handleUnauthorized(
            assetId: "asset",
            httpStatus: 401,
            grantAttempt: 0,
            failedGrantURL: stale.grantURL,
            fallback: { _ in }
        )
        async let second = store.handleUnauthorized(
            assetId: "asset",
            httpStatus: 403,
            grantAttempt: 0,
            failedGrantURL: stale.grantURL,
            fallback: { _ in }
        )
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        let callCount = await calls.value
        XCTAssertEqual(callCount, 2)
        await store.invalidateAll()
    }

    func testSecondUnauthorizedFallsBackWithoutAnotherGrant() async throws {
        let calls = Counter()
        let fallbacks = Counter()
        let now = Date()
        let store = E2eeRangeStreamingGrantStore(
            grantProvider: { assetId in
                _ = await calls.increment()
                return Self.grant(assetId: assetId, issuedAt: now)
            },
            clock: { now }
        )
        _ = try await store.grant(for: "asset")
        let result = await store.handleUnauthorized(
            assetId: "asset",
            httpStatus: 401,
            grantAttempt: 1,
            fallback: { _ in _ = await fallbacks.increment() }
        )
        XCTAssertNil(result)
        let callCount = await calls.value
        let fallbackCount = await fallbacks.value
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(fallbackCount, 1)
        await store.invalidateAll()
    }

    private static func grant(assetId: String, issuedAt: Date) -> E2eeRangeStreamingGrant {
        E2eeRangeStreamingGrant(
            assetId: assetId,
            grantURL: URL(string: "https://example.invalid/grant")!,
            expiresAt: issuedAt.addingTimeInterval(300),
            issuedAt: issuedAt
        )
    }
}
