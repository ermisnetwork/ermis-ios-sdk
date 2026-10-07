//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import XCTest

final class GroupInfoRepairCoordinatorTests: XCTestCase {
    private final class Store: GroupInfoRepairStore {
        var records: [StoredGroupInfoRefreshRequest] = []

        func load(scope: GroupInfoRepairScope) -> [StoredGroupInfoRefreshRequest] {
            records.filter { $0.scope == scope }
        }

        func upsert(_ record: StoredGroupInfoRefreshRequest) {
            records.removeAll {
                $0.scope == record.scope && $0.cid == record.cid
                    && $0.request.requestId == record.request.requestId
            }
            records.append(record)
        }

        func remove(scope: GroupInfoRepairScope, cid: String, throughEpoch: Int?, requestId: String?) {
            records.removeAll { record in
                guard record.scope == scope, record.cid == cid else { return false }
                if let epoch = throughEpoch { return record.request.minimumEpoch <= epoch }
                return requestId == nil || requestId == record.request.requestId
            }
        }
    }

    private let scope = GroupInfoRepairScope(accountId: "user-a", deviceId: "device-a")

    private func request(id: String = "request-a", epoch: Int = 7) -> GroupInfoRefreshRequestPayload {
        .init(
            requestId: id,
            minimumEpoch: epoch,
            deadlineAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSinceNow: 60),
            reason: "external_join_deadline",
            attemptCount: 1,
            leaseToken: nil,
            leaseExpiresAt: nil
        )
    }

    func testOneHundredDuplicatesProduceOneInFlightOwnerAndOneDurableRecord() {
        let store = Store()
        let coordinator = GroupInfoRepairCoordinator(store: store) { _, _, _ in }
        let winners = (0 ..< 100).filter { _ in
            coordinator.enqueue(scope: scope, cid: "team:a", request: request())
        }

        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(store.records.count, 1)
    }

    func testOfflineRecordSurvivesCoordinatorRestart() {
        let store = Store()
        let first = GroupInfoRepairCoordinator(store: store) { _, _, _ in }
        XCTAssertTrue(first.enqueue(scope: scope, cid: "team:a", request: request()))

        let restarted = GroupInfoRepairCoordinator(store: store) { _, _, _ in }
        XCTAssertEqual(restarted.pending(scope: scope).map(\.request.requestId), ["request-a"])
        XCTAssertTrue(restarted.enqueue(scope: scope, cid: "team:a", request: request()))
    }

    func testLeaseRetryBudgetIsBoundedAndJittered() {
        let coordinator = GroupInfoRepairCoordinator(store: Store()) { _, _, _ in }
        coordinator.random = { 0.5 }

        XCTAssertEqual(coordinator.retryDelay(attempt: 0), 0.25)
        XCTAssertEqual(coordinator.retryDelay(attempt: 1), 0.5)
        XCTAssertEqual(coordinator.retryDelay(attempt: 2), 1.0)
        XCTAssertNil(coordinator.retryDelay(attempt: 3))
    }

    func testRemovedMemberClearsAllChannelWork() {
        let store = Store()
        let coordinator = GroupInfoRepairCoordinator(store: store) { _, _, _ in }
        XCTAssertTrue(coordinator.enqueue(scope: scope, cid: "team:a", request: request(id: "old", epoch: 6)))
        coordinator.finish(cid: "team:a")
        XCTAssertTrue(coordinator.enqueue(scope: scope, cid: "team:a", request: request(id: "current", epoch: 7)))

        coordinator.clearRemoved(scope: scope, cid: "team:a")

        XCTAssertTrue(store.records.isEmpty)
    }

    func testAuthorizationLossIsTerminalButServerFailureIsRetryable() {
        for status in [401, 403, 404] {
            let error = ErmisApiError(type: .notAMemberOfChannel, statusCode: status, message: "removed")
            XCTAssertTrue(GroupInfoRepairCoordinator.shouldClearAfterServerFailure(error))
        }
        let retryable = ErmisApiError(type: .serviceUnavailable, statusCode: 503, message: "unavailable")
        XCTAssertFalse(GroupInfoRepairCoordinator.shouldClearAfterServerFailure(retryable))
    }

    func testNewerEpochClearsMatchingAndOlderButPreservesFutureWork() {
        let store = Store()
        let coordinator = GroupInfoRepairCoordinator(store: store) { _, _, _ in }
        [request(id: "old", epoch: 6), request(id: "current", epoch: 7), request(id: "future", epoch: 9)]
            .forEach { _ = coordinator.enqueue(scope: scope, cid: "team:a", request: $0) }

        coordinator.clearUploaded(scope: scope, cid: "team:a", requestId: "current", epoch: 8)

        XCTAssertEqual(store.records.map(\.request.requestId), ["future"])
    }

    func testDurableStorePreservesAdvancedSameIdAfterOldAckAndIsolatesScope() throws {
        let suite = "GroupInfoAckFence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsGroupInfoRepairStore(defaults: defaults)
        let other = GroupInfoRepairScope(accountId: "other", deviceId: "device-a")
        store.upsert(.init(scope: scope, cid: "team:a", request: request(id: "same", epoch: 7)))
        store.upsert(.init(scope: scope, cid: "team:a", request: request(id: "same", epoch: 9)))
        store.upsert(.init(scope: scope, cid: "team:a", request: request(id: "older", epoch: 6)))
        store.upsert(.init(scope: scope, cid: "team:b", request: request(id: "same", epoch: 6)))
        store.upsert(.init(scope: other, cid: "team:a", request: request(id: "same", epoch: 6)))
        store.remove(scope: scope, cid: "team:a", throughEpoch: 8, requestId: "same")
        let reopened = UserDefaultsGroupInfoRepairStore(defaults: defaults)
        XCTAssertEqual(reopened.load(scope: scope).filter { $0.cid == "team:a" }.map(\.request.minimumEpoch), [9])
        XCTAssertEqual(reopened.load(scope: other).count, 1)
        XCTAssertEqual(reopened.load(scope: scope).filter { $0.cid == "team:b" }.count, 1)
        reopened.remove(scope: scope, cid: "team:a", throughEpoch: 9, requestId: "different")
        XCTAssertTrue(reopened.load(scope: scope).filter { $0.cid == "team:a" }.isEmpty)
        reopened.remove(scope: scope, cid: "team:b", throughEpoch: nil, requestId: "other")
        XCTAssertEqual(reopened.load(scope: scope).count, 1)
        reopened.remove(scope: scope, cid: "team:b", throughEpoch: nil, requestId: "same")
        XCTAssertTrue(reopened.load(scope: scope).isEmpty)
        XCTAssertEqual(reopened.load(scope: other).count, 1)
    }

    func testRefreshRequestedWebSocketEventDecodesStrictVersionedMetadata() throws {
        let json = """
        {
          "type":"group_info.refresh_requested",
          "cid":"team:project:a",
          "request_id":"request-a",
          "minimum_epoch":7,
          "deadline_at":"2026-09-04T07:00:00Z",
          "expires_at":"2026-09-04T07:15:00Z",
          "reason":"external_join_deadline",
          "attempt_count":1,
          "version":1
        }
        """

        let event = try EventDecoder().decode(from: Data(json.utf8))
        let dto = try XCTUnwrap(event as? GroupInfoRefreshRequestedEventDTO)
        XCTAssertEqual(dto.cid.rawValue, "team:project:a")
        XCTAssertEqual(dto.request.minimumEpoch, 7)
        XCTAssertEqual(dto.version, 1)
    }

    func testUploadedWebSocketEventDecodesCoordinationMetadataOnly() throws {
        let json = """
        {
          "type":"group_info.uploaded",
          "cid":"team:project:a",
          "request_id":"request-a",
          "epoch":8,
          "hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "version":1
        }
        """

        let event = try EventDecoder().decode(from: Data(json.utf8))
        let dto = try XCTUnwrap(event as? GroupInfoUploadedEventDTO)
        XCTAssertEqual(dto.requestId, "request-a")
        XCTAssertEqual(dto.epoch, 8)
        XCTAssertEqual(dto.version, 1)
    }
}
