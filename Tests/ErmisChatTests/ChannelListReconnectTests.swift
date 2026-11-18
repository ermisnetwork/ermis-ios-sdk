import XCTest
@testable import ErmisChat

final class ChannelListReconnectTests: XCTestCase {
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

    private func fixture(invited: Bool = false) throws -> (ChannelListController, ListWorker) {
        var config = ErmisClientConfig(apiKeyString: "fixture-key",
            endpointEnviroment: .init(baseURL: URL(string: "https://example.invalid")!), isErmis: false)
        config.localStorageScope = .inMemory
        config.localStorageNamespace = "reconnect-test-\(UUID().uuidString)"
        config.isClientInActiveMode = false
        var environment = ErmisClient.Environment()
        environment.backgroundTaskSchedulerBuilder = { nil }
        environment.webSocketClientBuilder = nil
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
        let query = ChannelListQuery(filter: .allChannels(memberId: "user", projectId: "project"))
        let list: ChannelListController = invited
            ? InvitedChannelListController(query: query, client: client, environment: listEnvironment)
            : ChannelListController(query: query, client: client, environment: listEnvironment)
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
}
