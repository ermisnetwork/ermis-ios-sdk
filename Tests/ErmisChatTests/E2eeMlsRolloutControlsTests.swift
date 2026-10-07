import XCTest
@testable import ErmisChat

final class E2eeMlsRolloutControlsTests: XCTestCase {
    func testKeyPackageInventoryContractUsesServerTargetAndDurableDemand() throws {
        let inventory = try JSONDecoder.default.decode(
            KeyPackagesCountPayload.self,
            from: Data(
                #"{"remaining":12,"target":100,"low_watermark":50,"requested_delta":88,"refill_generation":3}"#.utf8
            )
        )

        XCTAssertEqual(inventory.remaining, 12)
        XCTAssertEqual(inventory.target, 100)
        XCTAssertEqual(inventory.lowWatermark, 50)
        XCTAssertEqual(inventory.requestedDelta, 88)
        XCTAssertEqual(inventory.refillGeneration, 3)
        XCTAssertEqual(
            E2eeKeyPackageRefillPolicy.batchSize(
                remaining: inventory.remaining,
                target: inventory.target,
                lowWatermark: inventory.lowWatermark,
                requestedDelta: inventory.requestedDelta,
                refillGeneration: inventory.refillGeneration
            ),
            88
        )

        let upload = try JSONDecoder.default.decode(
            UploadKeyPackagesPayload.self,
            from: Data(
                #"{"stored":88,"total_remaining":100,"target":100,"low_watermark":50,"requested_delta":0,"refill_generation":null,"batch_id":"batch","validation_version":1}"#.utf8
            )
        )
        XCTAssertEqual(upload.stored, 88)
        XCTAssertEqual(upload.totalRemaining, 100)
        XCTAssertEqual(upload.target, 100)
        XCTAssertEqual(upload.lowWatermark, 50)
        XCTAssertEqual(upload.requestedDelta, 0)
        XCTAssertNil(upload.refillGeneration)
        XCTAssertEqual(upload.batchId, "batch")
        XCTAssertEqual(upload.validationVersion, 1)
    }

    func testKeyPackageRefillPolicyRejectsContradictoryOrUnboundedContracts() {
        XCTAssertEqual(
            E2eeKeyPackageRefillPolicy.batchSize(
                remaining: 60,
                target: 100,
                lowWatermark: 50,
                requestedDelta: 40,
                refillGeneration: nil
            ),
            0
        )
        XCTAssertNil(
            E2eeKeyPackageRefillPolicy.batchSize(
                remaining: 12,
                target: 100,
                lowWatermark: 50,
                requestedDelta: 87,
                refillGeneration: 3
            )
        )
        XCTAssertNil(
            E2eeKeyPackageRefillPolicy.batchSize(
                remaining: 12,
                target: 101,
                lowWatermark: 50,
                requestedDelta: 89,
                refillGeneration: 3
            )
        )
        XCTAssertNil(
            E2eeKeyPackageRefillPolicy.batchSize(
                remaining: 50,
                target: 100,
                lowWatermark: 100,
                requestedDelta: 50,
                refillGeneration: 3
            )
        )
    }

    func testKeyPackageInventoryEndpointUsesAuthenticatedDeviceAndReason() throws {
        let endpoint: Endpoint<KeyPackagesCountPayload> = .keyPackagesCount(reason: "manual")

        XCTAssertEqual(endpoint.path.value, "v1/e2ee/key_packages/count")
        XCTAssertEqual(endpoint.method, .get)
        XCTAssertTrue(endpoint.needToken)
        XCTAssertTrue(endpoint.needDeviceId)
        XCTAssertEqual(
            try XCTUnwrap(endpoint.query as? [String: String])["reason"],
            "manual"
        )
    }

    func testKeyPackageRefillEventDecodesBoundedVersionedHint() throws {
        let event = try EventDecoder().decode(
            from: Data(
                #"{"type":"key_packages.low","idempotency_key":"opaque","device_id":"device","usable_count":12,"target":100,"requested_delta":88,"reason":"consume","generation":3,"version":1}"#.utf8
            )
        )
        let refill = try XCTUnwrap(event as? KeyPackageRefillEventDTO).refill

        XCTAssertEqual(refill.usableCount, 12)
        XCTAssertEqual(refill.target, 100)
        XCTAssertEqual(refill.requestedDelta, 88)
        XCTAssertEqual(refill.generation, 3)
    }

    func testControlsDefaultEnabledForCompatibility() {
        let controls = E2eeMlsRolloutControls()

        XCTAssertTrue(controls.historicalReplayEnabled)
        XCTAssertTrue(controls.partialWelcomeFallbackEnabled)
        XCTAssertTrue(controls.groupInfoRepairEnabled)
        XCTAssertTrue(controls.clientTelemetryEnabled)
        XCTAssertNil(controls.metricObserver)
    }

    func testControlsDisableIndependentlyAndEmitBoundedObservation() {
        let observed = expectation(description: "bounded rollout observation")
        let controls = E2eeMlsRolloutControls(
            historicalReplayEnabled: false,
            partialWelcomeFallbackEnabled: true,
            groupInfoRepairEnabled: false,
            clientTelemetryEnabled: false,
            metricObserver: { metric in
                XCTAssertEqual(metric.name, .delayedCommit)
                XCTAssertEqual(metric.outcome, .failure)
                XCTAssertEqual(metric.reason, .processError)
                observed.fulfill()
            }
        )

        XCTAssertFalse(controls.historicalReplayEnabled)
        XCTAssertTrue(controls.partialWelcomeFallbackEnabled)
        XCTAssertFalse(controls.groupInfoRepairEnabled)
        XCTAssertFalse(controls.clientTelemetryEnabled)
        controls.metricObserver?(
            .init(name: .delayedCommit, outcome: .failure, reason: .processError)
        )
        wait(for: [observed], timeout: 1)
    }

    func testTelemetryEndpointUsesAuthenticatedDeviceTransportAndBoundedBody() throws {
        let endpoint: Endpoint<E2eeMlsRolloutTelemetryPayload> = .reportMlsRolloutTelemetry(
            observations: [
                .init(name: .delayedCommit, outcome: .failure, reason: .processError)
            ]
        )

        XCTAssertEqual(endpoint.path.value, "v1/e2ee/rollout/telemetry")
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertTrue(endpoint.needToken)
        XCTAssertTrue(endpoint.needDeviceId)
        let body = try XCTUnwrap(endpoint.body as? E2eeMlsRolloutTelemetryRequestBody)
        let data = try JSONEncoder.default.encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["platform"] as? String, "ios")
        let observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0]["name"] as? String, "delayed_commit")
        XCTAssertEqual(observations[0]["outcome"] as? String, "failure")
        XCTAssertEqual(observations[0]["reason"] as? String, "process_error")
        XCTAssertNil(object["user_id"])
        XCTAssertNil(object["device_id"])
        XCTAssertNil(object["cid"])
    }

    func testTelemetryBufferIsSingleFlightBoundedAndContinuesAfterFailureCompletion() {
        let lock = NSLock()
        var batches: [[E2eeMlsRolloutMetricObservation]] = []
        var completions: [() -> Void] = []
        let buffer = E2eeMlsRolloutTelemetryBuffer { batch, completion in
            lock.lock()
            batches.append(batch)
            completions.append(completion)
            lock.unlock()
        }
        let observation = E2eeMlsRolloutMetricObservation(
            name: .delayedCommit,
            outcome: .failure,
            reason: .processError
        )

        XCTAssertEqual(buffer.record(observation), .accepted)
        for _ in 0..<32 {
            XCTAssertEqual(buffer.record(observation), .accepted)
        }
        XCTAssertEqual(buffer.record(observation), .droppedQueueFull)
        XCTAssertEqual(buffer.pendingCountForTesting, 32)
        XCTAssertEqual(batches.map(\.count), [1])

        completions.removeFirst()()
        XCTAssertEqual(batches.map(\.count), [1, 16])
        completions.removeFirst()()
        XCTAssertEqual(batches.map(\.count), [1, 16, 16])
        completions.removeFirst()()
        XCTAssertEqual(buffer.pendingCountForTesting, 0)
    }

    func testPartialWelcomeFallbackRequiresTypedPrerequisite() {
        XCTAssertEqual(
            E2eePartialWelcomeFallbackEligibility.resolve(
                hasTypedPrerequisite: false,
                controlEnabled: true
            ),
            .missingTypedPrerequisite
        )
        XCTAssertEqual(
            E2eePartialWelcomeFallbackEligibility.resolve(
                hasTypedPrerequisite: true,
                controlEnabled: false
            ),
            .disabled
        )
        XCTAssertEqual(
            E2eePartialWelcomeFallbackEligibility.resolve(
                hasTypedPrerequisite: true,
                controlEnabled: true
            ),
            .eligible
        )
    }

    func testConcurrentBootstrapAdmissionCreatesOneJoinCandidatePerScope() throws {
        let queue = E2eeBootstrapQueue()
        let cid = try ChannelId(cid: "messaging:project:rollout-bootstrap")
        let resultLock = NSLock()
        var admittedCount = 0

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if queue.enqueue(cid) {
                resultLock.lock()
                admittedCount += 1
                resultLock.unlock()
            }
        }

        XCTAssertEqual(admittedCount, 1)
        XCTAssertEqual(queue.dequeue()?.rawValue, cid.rawValue)
        XCTAssertTrue(queue.deferSyncIfAdmitted(cid))
        XCTAssertTrue(queue.finish(cid))
        XCTAssertNil(queue.dequeue())
        XCTAssertTrue(queue.enqueue(cid))
    }
}
