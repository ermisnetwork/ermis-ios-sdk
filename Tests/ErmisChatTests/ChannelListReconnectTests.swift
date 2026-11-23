import XCTest
@testable import ErmisChat
import ErmisChatUI
import UIKit
import CoreData

final class ChannelListReconnectTests: XCTestCase {
    private final class TopicView: TopicListViewController {
        override var isChannelListStatesEnabled: Bool { true }
    }
    private final class RootView: ChannelListViewController {
        override var isChannelListStatesEnabled: Bool { true }
    }
    private final class ProfileAPI: APIClient {
        var pending: [(Result<UserListPayload, Error>) -> Void] = []
        override func request<Response: Decodable>(endpoint: Endpoint<Response>, completion: @escaping (Result<Response, Error>) -> Void) {
            guard case .userBatch = endpoint.path else {
                completion(.failure(ClientError("Unexpected profile fixture endpoint"))); return
            }
            pending.append { result in completion(result.map { $0 as! Response }) }
        }
        func finish(_ index: Int, ids: [String]) throws {
            let raw: [String: Any] = ["data": ids.map { ["id": $0, "project_id": "project", "name": "Name-\($0)"] },
                "page": 1, "count": ids.count, "page_count": 1, "total": ids.count]
            let payload = try JSONDecoder.default.decode(UserListPayload.self, from: JSONSerialization.data(withJSONObject: raw))
            pending[index](.success(payload))
        }
    }
    private final class ProfileSaveFailureDatabase: DatabaseContainer {
        var failNextWrite = false
        override func write(_ actions: @escaping (DatabaseSession) throws -> Void, completion: @escaping (Error?) -> Void,
                            file: StaticString = #fileID, line: UInt = #line) {
            let fail = failNextWrite; failNextWrite = false
            super.write({ session in
                try actions(session)
                if fail { throw ClientError("Profile fixture save failure") }
            }, completion: { error in
                if error != nil { self.writableContext.rollback() }
                completion(error)
            }, file: file, line: line)
        }
    }
    private final class ListWorker: ChannelListUpdater {
        private let lock = NSLock()
        private var completions: [(Result<[Channel], Error>) -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return completions.count }
        override func update(channelListQuery: ChannelListQuery, userId: String?,
                             completion: ((Result<[Channel], Error>) -> Void)? = nil) {
            lock.lock(); completions.append(completion ?? { _ in }); lock.unlock()
        }
        func finish(_ index: Int, _ result: Result<[Channel], Error> = .success([])) {
            lock.lock()
            guard completions.indices.contains(index) else { lock.unlock(); return }
            let work = completions[index]; lock.unlock(); work(result)
        }
    }

    private func fixture(invited: Bool = false, topic: Bool = false, profiles: Bool = false,
                         database: DatabaseContainer? = nil) throws -> (ChannelListController, ListWorker) {
        var config = ErmisClientConfig(apiKeyString: "fixture-key",
            endpointEnviroment: .init(baseURL: URL(string: "https://example.invalid")!), isErmis: false)
        config.localStorageScope = .inMemory
        config.localStorageNamespace = "reconnect-test-\(UUID().uuidString)"
        config.isClientInActiveMode = false
        var environment = ErmisClient.Environment()
        environment.backgroundTaskSchedulerBuilder = { nil }
        environment.webSocketClientBuilder = nil
        if profiles {
            environment.apiClientBuilder = { ProfileAPI(sessionConfiguration: $0, requestEncoder: $1,
                requestDecoder: $2, uploader: $3, downloader: $4) }
        }
        if let database { environment.databaseContainerBuilder = { _, _, _, _, _, _ in database } }
        let client = ErmisClient(config: config, clientId: "fixture", projectId: "project",
            rootProjectId: "project", chainId: 1, environment: environment,
            notificationTokenProvider: DefaultNotificationTokenProvider(),
            factory: ErmisClientFactory(config: config, environment: environment))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !client.databaseContainer.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        client.authenticationRepository.setToken(token: Token(rawValue: "fixture", userId: "user",
            clientId: "fixture", projectId: "project", chainId: 1, isErmis: false, expiration: nil), completeTokenWaiters: true)
        let worker = ListWorker(database: client.databaseContainer, apiClient: client.apiClient, e2eRepository: nil)
        var listEnvironment = ChannelListController.Environment()
        listEnvironment.channelQueryUpdaterBuilder = { _, _, _ in worker }
        let parent = try ChannelId(cid: "team:project:parent")
        let query = ChannelListQuery(filter: topic ? .topics(parentcID: parent, projectId: "project") : .allChannels(memberId: "user", projectId: "project"))
        let list: ChannelListController = invited
            ? InvitedChannelListController(query: query, client: client, parentCid: topic ? parent : nil, environment: listEnvironment)
            : ChannelListController(query: query, client: client, parentCid: topic ? parent : nil, environment: listEnvironment)
        return (list, worker)
    }

    private func emit(_ state: WebSocketConnectionState, to list: ChannelListController) {
        list.eventsController(list.eventsController, didReceiveEvent: ConnectionStatusUpdated(webSocketConnectionState: state))
    }
    private func awaitCount(_ expected: Int, _ worker: ListWorker, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in worker.count == expected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 2), .completed, file: file, line: line)
    }
    private func drain() {
        let flushed = expectation(description: "queued callbacks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { flushed.fulfill() }
        wait(for: [flushed], timeout: 1)
    }

    func testReconnectRefetchesExistingRegularAndInvitedListsWithoutRestart() throws {
        for invited in [false, true] {
            let (list, worker) = try fixture(invited: invited)
            list.state = .remoteDataFetched
            emit(.disconnected(source: .systemInitiated), to: list)
            emit(.connected(connectionId: "first"), to: list)
            awaitCount(1, worker)
            worker.finish(0)
            drain()
        }
    }

    func testHealthAndDuplicateConnectedDoNotRefetchOrStartUnusedList() throws {
        let (unused, unusedWorker) = try fixture()
        emit(.connected(connectionId: "first"), to: unused)
        drain()
        XCTAssertEqual(unusedWorker.count, 0)
        let (list, worker) = try fixture()
        list.state = .remoteDataFetched
        emit(.connected(connectionId: "first"), to: list)
        awaitCount(1, worker)
        list.eventsController(list.eventsController, didReceiveEvent: HealthCheckEvent(connectionId: "heartbeat"))
        emit(.connected(connectionId: "first"), to: list)
        worker.finish(0)
        drain()
        XCTAssertEqual(worker.count, 1)
    }

    func testReconnectDuringOlderRequestQueuesOneFollowUpAndCoalescesSynchronize() throws {
        let (list, worker) = try fixture()
        list.synchronize()
        awaitCount(1, worker)
        let coalesced = expectation(description: "coalesced completion")
        list.synchronize { error in XCTAssertNil(error); coalesced.fulfill() }
        emit(.disconnected(source: .systemInitiated), to: list)
        emit(.connected(connectionId: "new"), to: list)
        emit(.connected(connectionId: "new"), to: list)
        drain()
        XCTAssertEqual(worker.count, 1)
        worker.finish(0)
        awaitCount(2, worker)
        worker.finish(1)
        wait(for: [coalesced], timeout: 2)
        drain()
        XCTAssertEqual(worker.count, 2)
    }

    func testFailedListCanRecoverOnNextConnection() throws {
        let (list, worker) = try fixture()
        list.state = .remoteDataFetchFailed(ClientError(with: URLError(.notConnectedToInternet)))
        emit(.connected(connectionId: "retry"), to: list)
        awaitCount(1, worker)
        worker.finish(0)
        drain()
        XCTAssertEqual(list.state, .remoteDataFetched)
    }

    func testReplacedSessionCannotPublishOrStartQueuedReconnect() throws {
        let (list, worker) = try fixture()
        list.state = .remoteDataFetched
        emit(.connected(connectionId: "old"), to: list)
        awaitCount(1, worker)
        emit(.disconnected(source: .systemInitiated), to: list)
        list.client.apiClient.flushRequestsQueue()
        list.client.activeChannelListControllers.removeAllObjects()
        emit(.connected(connectionId: "replacement"), to: list)
        worker.finish(0, .failure(URLError(.notConnectedToInternet)))
        drain()
        XCTAssertEqual(worker.count, 1)
        XCTAssertEqual(list.state, .remoteDataFetched, "Old completion cannot replace the controller state")
    }

    func testCancelledTransportStillRefetchesForSameAccountAfterReconnect() throws {
        let (list, worker) = try fixture()
        list.state = .remoteDataFetched
        emit(.connected(connectionId: "old"), to: list)
        awaitCount(1, worker)
        emit(.disconnected(source: .userInitiated), to: list)
        list.client.apiClient.flushRequestsQueue()
        emit(.connected(connectionId: "new"), to: list)
        drain()
        worker.finish(0)
        awaitCount(2, worker)
        worker.finish(1)
        drain()
        XCTAssertEqual(list.state, .remoteDataFetched)
    }
    func testInitialTopicRequestCancelledByTransportEndsLoadingForCurrentSession() throws {
        let (list, worker) = try fixture(topic: true)
        // First entry: observer is ready but no authoritative response exists yet.
        list.synchronize()
        awaitCount(1, worker)
        XCTAssertEqual(list.state, .localDataFetched)
        list.client.apiClient.flushRequestsQueue()
        worker.finish(0, .failure(URLError(.cancelled)))
        drain()
        guard case .remoteDataFetchFailed = list.state else {
            return XCTFail("Current-session transport cancellation left first-entry loading at \(list.state)")
        }
    }

    func testFirstTopicFailureShowsErrorWithoutClaimingAuthoritativeEmpty() throws {
        let (list, worker) = try fixture(topic: true)
        let view = TopicView.make(with: list)
        view.loadViewIfNeeded()
        awaitCount(1, worker)
        worker.finish(0, .failure(URLError(.notConnectedToInternet)))
        drain()
        XCTAssertTrue(view.topicListLoadingView.isHidden)
        XCTAssertFalse(view.topicListErrorView.isHidden)
        XCTAssertTrue(view.emptyView.isHidden, "Failed discovery is not a verified empty topic list")
    }

    func testLateStateFromReplacedTopicControllerCannotRestoreLoading() throws {
        let (old, _) = try fixture(topic: true)
        let (current, _) = try fixture(topic: true)
        let view = TopicView.make(with: current)
        view.loadViewIfNeeded()
        current.state = .remoteDataFetched
        drain()
        XCTAssertTrue(view.topicListLoadingView.isHidden)
        view.controller(old, didChangeState: .localDataFetched)
        XCTAssertTrue(view.topicListLoadingView.isHidden, "Retired navigation/session callback must be ignored")
    }

    func testInitialTopicCancellationCanRetryToAuthoritativeEmptyWithoutRelaunch() throws {
        let (list, worker) = try fixture(topic: true)
        let view = TopicView.make(with: list)
        view.loadViewIfNeeded()
        awaitCount(1, worker)
        list.client.apiClient.flushRequestsQueue()
        worker.finish(0, .failure(URLError(.cancelled)))
        drain()
        XCTAssertTrue(view.topicListLoadingView.isHidden)
        XCTAssertFalse(view.topicListErrorView.isHidden)
        XCTAssertTrue(view.emptyView.isHidden)
        view.topicListErrorView.refreshButtonAction?()
        XCTAssertFalse(view.topicListLoadingView.isHidden)
        // The error banner may still be animating away while retry is in flight.
        // Its terminal visibility is asserted after the authoritative result below.
        awaitCount(2, worker)
        worker.finish(1)
        drain()
        XCTAssertTrue(view.topicListLoadingView.isHidden)
        XCTAssertTrue(view.topicListErrorView.isHidden)
        XCTAssertFalse(view.emptyView.isHidden)
        view.beginAppearanceTransition(false, animated: false)
        view.endAppearanceTransition()
        view.beginAppearanceTransition(true, animated: false)
        view.endAppearanceTransition()
        XCTAssertEqual(worker.count, 2, "Navigation does not create another discovery query")
    }

    func testFirstTopicObserverPublishesGeneralAndChildrenBeforeAndAfterViewInitialization() throws {
        for storeBeforeView in [true, false] {
            let (list, worker) = try fixture(topic: true)
            let parent = "team:project:parent"
            let cids = [parent, "topic:project:child", "topic:project:gated", "topic:project:other"]
            let rows: [[String: Any]] = cids.enumerated().map { index, cid in
                var channel: [String: Any] = ["cid": cid, "type": index == 0 ? "team" : "topic",
                    "created_at": "2026-11-19T00:00:00Z", "updated_at": "2026-11-19T00:00:00Z",
                    "member_count": 1, "members": [], "mls_enabled": false]
                if index > 0 { channel["parent_cid"] = index == 3 ? "team:project:elsewhere" : parent }
                channel["gate"] = index == 2
                return ["channel": channel, "membership": ["user_id": "user", "channel_role": "member"],
                    "messages": [], "read": []]
            }
            let payload = try JSONDecoder.default.decode(ChannelListPayload.self,
                from: JSONSerialization.data(withJSONObject: ["channels": rows]))
            func persist() {
                let saved = expectation(description: "Discovery metadata persisted")
                list.client.databaseContainer.write { session in
                    session.saveChannelList(payload: payload, query: list.query)
                } completion: { error in XCTAssertNil(error); saved.fulfill() }
                wait(for: [saved], timeout: 2)
            }
            if storeBeforeView { persist() }
            let view = TopicView.make(with: list)
            view.loadViewIfNeeded()
            awaitCount(1, worker)
            if !storeBeforeView { persist() }
            worker.finish(0)
            let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                view.channels.count == 3 && view.topicListLoadingView.isHidden
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 3), .completed)
            let expected = Set(cids.prefix(3))
            XCTAssertEqual(Set(view.channels.map { $0.cid.rawValue }), expected)
            XCTAssertTrue(view.emptyView.isHidden)
            XCTAssertTrue(view.topicListErrorView.isHidden)
            view.beginAppearanceTransition(false, animated: false)
            view.endAppearanceTransition()
            view.beginAppearanceTransition(true, animated: false)
            view.endAppearanceTransition()
            view.reloadChannels()
            drain()
            XCTAssertEqual(view.channels.count, 3)
            XCTAssertEqual(Set(view.channels.map { $0.cid.rawValue }), expected)
            XCTAssertEqual(worker.count, 1)
        }
    }

    func testRetryFailureCannotBeHiddenByAnOlderDismissAnimation() {
        let error = TopicListErrorView()
        error.show()
        error.hide()
        error.show() // A fast retry failed while the existing 0.5s hide was pending.
        XCTAssertFalse(error.isHidden)
        let animationSettled = expectation(description: "Existing hide animation completion")
        // Test-only observation of the component's existing animation, not a product retry delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { animationSettled.fulfill() }
        wait(for: [animationSettled], timeout: 1)
        XCTAssertFalse(error.isHidden, "The new error must outlive an old hide completion")
    }

    func testValidLocalTopicRowsAreUsableWhileRemoteDiscoveryIsPending() throws {
        let (list, worker) = try fixture(topic: true)
        let raw: [String: Any] = ["channels": [["channel": ["cid": "team:project:parent", "type": "team",
            "created_at": "2026-11-19T00:00:00Z", "updated_at": "2026-11-19T00:00:00Z",
            "members": [], "member_count": 1, "mls_enabled": false], "messages": [], "read": [],
            "membership": ["user_id": "user", "channel_role": "member"]]]]
        let payload = try JSONDecoder.default.decode(ChannelListPayload.self,
            from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(payload.channels.count, 1, "Fixture must decode a real authorized row before measuring loading")
        let saved = expectation(description: "Current-account General persisted")
        list.client.databaseContainer.write { session in
            session.saveChannelList(payload: payload, query: list.query)
        } completion: { error in XCTAssertNil(error); saved.fulfill() }
        wait(for: [saved], timeout: 2)
        let view = TopicView.make(with: list)
        view.loadViewIfNeeded()
        awaitCount(1, worker)
        let bound = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in view.channels.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [bound], timeout: 2), .completed)
        XCTAssertEqual(list.state, .localDataFetched)
        XCTAssertTrue(view.topicListLoadingView.isHidden, "Validated local rows must remain usable during remote refresh")
        XCTAssertTrue(view.emptyView.isHidden)
        XCTAssertTrue(view.topicListErrorView.isHidden)
        worker.finish(0)
        drain()
    }

    func testInitialRootQueryRemainsLoadingUntilAnAuthoritativeEmptyResponse() throws {
        let (list, worker) = try fixture()
        let view = RootView.make(with: list)
        view.loadViewIfNeeded()
        awaitCount(1, worker)
        XCTAssertEqual(list.state, .localDataFetched)
        XCTAssertTrue(view.emptyView.isHidden)
        XCTAssertFalse(view.channelListLoadingView.isHidden)
        worker.finish(0)
        drain()
        XCTAssertTrue(view.channelListLoadingView.isHidden)
        XCTAssertFalse(view.emptyView.isHidden)
    }

    private func persistProfileRow(_ list: ChannelListController, peer: String, topic: Bool = false) throws {
        let cid = topic ? "team:project:parent" : "messaging:project:profile-\(peer)"
        let raw: [String: Any] = ["channels": [["channel": ["cid": cid, "type": topic ? "team" : "messaging",
            "created_at": "2026-11-19T00:00:00Z", "updated_at": "2026-11-19T00:00:00Z",
            "members": [["user_id": peer, "user": ["id": peer, "project_id": "project"], "channel_role": "member"],
                        ["user_id": "user", "user": ["id": "user", "project_id": "project", "name": "Me"], "channel_role": "member"]],
            "member_count": 2, "mls_enabled": false], "messages": [], "read": [],
            "membership": ["user_id": "user", "channel_role": "member",
                           "user": ["id": "user", "project_id": "project", "name": "Me"]]]]]
        let payload = try JSONDecoder.default.decode(ChannelListPayload.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(payload.channels.count, 1)
        let saved = expectation(description: "Persist authorized row with ID-only member")
        list.client.databaseContainer.write { session in session.saveChannelList(payload: payload, query: list.query) }
            completion: { error in XCTAssertNil(error); saved.fulfill() }
        wait(for: [saved], timeout: 2)
    }

    func testLocalRootAndTopicRowsFetchProfilesBeforeRemoteCompletesAndUpdateWithoutNavigation() throws {
        for topic in [false, true] {
            let (list, worker) = try fixture(topic: topic, profiles: true)
            try persistProfileRow(list, peer: "peer", topic: topic)
            let api = try XCTUnwrap(list.client.apiClient as? ProfileAPI)
            let root = topic ? nil : RootView.make(with: list)
            let topics = topic ? TopicView.make(with: list) : nil
            (root as UIViewController? ?? topics!).loadViewIfNeeded()
            awaitCount(1, worker)
            XCTAssertEqual(list.channels.count, 1, "Fixture must satisfy the real project/member/role filter")
            let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in api.pending.count == 1 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 2), .completed,
                           "ID-only cached rows must request profiles while remote discovery is held")
            XCTAssertEqual(list.state, .localDataFetched)
            guard api.pending.count == 1 else { worker.finish(0); continue }
            try api.finish(0, ids: ["peer"])
            let named = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (root?.channels ?? topics!.channels).contains { $0.lastActiveMembers.contains { $0.displayName == "Name-peer" } }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 2), .completed, "Name must update without topic navigation")
            if let channel = root?.channels.first {
                XCTAssertEqual(DefaultChannelNameFormatter().format(channel: channel, forCurrentUserId: "user"), "Name-peer")
            }
            worker.finish(0); drain()
            XCTAssertEqual(api.pending.count, 1, "Successful IDs are not fetched again after remote completion")
        }
    }

    func testProfileCompletionOccursAfterCommitAndSaveFailureIsNotSuccess() throws {
        for fail in [false, true] {
            let db = ProfileSaveFailureDatabase(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
            let (list, _) = try fixture(profiles: true, database: db)
            let api = try XCTUnwrap(list.client.apiClient as? ProfileAPI)
            db.failNextWrite = fail
            let finished = expectation(description: "Profile completion reflects durable result")
            list.client.fetchUsers(with: ["peer"]) { result in
                if fail {
                    if case .success = result { XCTFail("Uncommitted profile cannot report success") }
                } else {
                    XCTAssertFalse(db.writableContext.hasChanges, "Completion must follow the DB commit")
                    XCTAssertEqual(try? result.get().first?.displayName, "Name-peer")
                }
                finished.fulfill()
            }
            XCTAssertEqual(api.pending.count, 1)
            try api.finish(0, ids: ["peer"])
            wait(for: [finished], timeout: 2)
        }
    }

    func testRetiredProfileResponseCannotWriteToReplacementSession() throws {
        let (list, _) = try fixture(profiles: true)
        let api = try XCTUnwrap(list.client.apiClient as? ProfileAPI)
        let finished = expectation(description: "Retired profile response rejected")
        list.client.fetchUsers(with: ["peer"]) { result in
            if case .success = result { XCTFail("Retired response must not publish profiles") }
            finished.fulfill()
        }
        api.flushRequestsQueue()
        try api.finish(0, ids: ["peer"])
        wait(for: [finished], timeout: 2)
        let checked = expectation(description: "No retired user persisted")
        list.client.databaseContainer.writableContext.perform {
            XCTAssertNil(UserDTO.load(id: "peer", projectId: "project", context: list.client.databaseContainer.writableContext))
            checked.fulfill()
        }
        wait(for: [checked], timeout: 2)
    }

    func testProfilesDiscoveredDuringAnInFlightBatchAreDrainedWithoutDuplicateRequests() throws {
        let (list, worker) = try fixture(profiles: true)
        try persistProfileRow(list, peer: "peer-first")
        let api = try XCTUnwrap(list.client.apiClient as? ProfileAPI)
        let view = RootView.make(with: list); view.loadViewIfNeeded()
        awaitCount(1, worker)
        XCTAssertEqual(list.channels.count, 1, "Initial root row must pass the production membership filter")
        let first = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in api.pending.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [first], timeout: 2), .completed)
        guard api.pending.count == 1 else { return XCTFail("No first profile batch") }
        try persistProfileRow(list, peer: "peer-later")
        drain()
        XCTAssertEqual(api.pending.count, 1, "Only one profile batch per view may be in flight")
        try api.finish(0, ids: ["peer-first"])
        let second = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in api.pending.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 2), .completed)
        guard api.pending.count == 2 else { return XCTFail("Later metadata rows were not drained") }
        try api.finish(1, ids: ["peer-later"])
        let named = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let names = Set(view.channels.flatMap { $0.lastActiveMembers }.compactMap { $0.name })
            return names.contains("Name-peer-first") && names.contains("Name-peer-later")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 2), .completed)
        worker.finish(0); drain(); view.reloadChannels(); drain()
        XCTAssertEqual(api.pending.count, 2)
    }

}
