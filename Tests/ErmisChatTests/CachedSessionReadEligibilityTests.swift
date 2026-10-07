import CoreData
import XCTest
@testable import ErmisChat

final class CachedSessionReadEligibilityTests: XCTestCase {
    private final class Monitor: InternetConnectionMonitor {
        weak var delegate: InternetConnectionDelegate?
        var status: InternetConnection.Status
        init(_ status: InternetConnection.Status) { self.status = status }
        func start() {}
        func stop() {}
    }

    private func token(user: String = "cached-user", project: String = "cached-project", expiration: Date? = nil) -> Token {
        Token(rawValue: "fixture", userId: user, clientId: "fixture-client", projectId: project,
              chainId: 1, isErmis: false, expiration: expiration)
    }

    private func withClient(
        status: InternetConnection.Status = .unavailable,
        scope: ErmisLocalStorageScope = .user("cached-user"),
        memoryStoreFallback: Bool = false,
        _ body: (ErmisClient) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cached-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = ErmisClientConfig(
            apiKeyString: "fixture-key",
            endpointEnviroment: .init(baseURL: try XCTUnwrap(URL(string: "https://example.invalid"))),
            isErmis: false
        )
        config.localStorageFolderURL = root
        config.localStorageScope = scope
        var environment = ErmisClient.Environment()
        environment.monitor = Monitor(status)
        environment.backgroundTaskSchedulerBuilder = { nil }
        if memoryStoreFallback {
            environment.databaseContainerBuilder = { _, _, _, _, _, _ in
                DatabaseContainer(kind: .inMemory, shouldResetEphemeralValuesOnStart: false)
            }
        }
        let client = ErmisClient(
            config: config, clientId: "fixture-client", projectId: "cached-project",
            rootProjectId: "cached-project", chainId: 1, environment: environment,
            notificationTokenProvider: DefaultNotificationTokenProvider(),
            factory: ErmisClientFactory(config: config, environment: environment)
        )
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !client.databaseContainer.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        client.authenticationRepository.setToken(token: token(), completeTokenWaiters: true)
        defer {
            for context in client.databaseContainer.allContext { context.performAndWait { context.reset() } }
            for store in client.databaseContainer.persistentStoreCoordinator.persistentStores {
                try? client.databaseContainer.persistentStoreCoordinator.remove(store)
            }
        }
        try body(client)
    }

    private func saveAccount(in database: DatabaseContainer, user: String = "cached-user", project: String = "cached-project") throws {
        let now = Date()
        let payload = CurrentUserPayload(
            id: user, projectId: project, name: "Cached user", imageURL: nil, phone: nil, email: nil,
            role: .user, createdAt: now, updatedAt: now, deactivatedAt: nil, lastActiveAt: now,
            isOnline: false, isInvisible: false, isBanned: false, isBlocked: false, language: nil,
            isEmailVerified: true, bellBoyId: "", aboutMe: ""
        )
        try database.writeAndWait { session in
            try session.saveCurrentUser(payload: payload, projectId: project)
        }
    }

    func testDiskCacheSurvivesReopenAndRemainsReadableWithoutConnection() throws {
        try withClient { client in
            let database = client.databaseContainer
            try saveAccount(in: database)
            let store = try XCTUnwrap(database.persistentStoreCoordinator.persistentStores.first)
            let storeURL = try XCTUnwrap(store.url)
            for context in database.allContext { context.performAndWait { context.reset() } }
            try database.persistentStoreCoordinator.remove(store)
            _ = try database.persistentStoreCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL,
                options: [NSMigratePersistentStoresAutomaticallyOption: true,
                          NSInferMappingModelAutomaticallyOption: true]
            )
            XCTAssertTrue(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: token()))
            XCTAssertEqual(client.currentUserController().dataStore.currentUser(of: "cached-project")?.id, "cached-user")
            XCTAssertNotEqual(client.connectionStatus, .connected)
        }
    }

    func testNoCachedAccountRemainsBlocked() throws {
        try withClient { client in
            XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: token()))
        }
    }

    func testCachedWrongAccountOrProjectRemainsBlocked() throws {
        for (user, project) in [("other-user", "cached-project"), ("cached-user", "other-project")] {
            try withClient { client in
                try saveAccount(in: client.databaseContainer, user: user, project: project)
                XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: token()))
            }
        }
    }

    func testTokenAccountProjectAndExpiryMustMatchSession() throws {
        try withClient { client in
            try saveAccount(in: client.databaseContainer)
            for invalid in [token(user: "other-user"), token(project: "other-project"), token(expiration: Date.distantPast)] {
                XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: invalid))
            }
        }
    }

    func testUnknownAndAvailableNetworkDoNotAdmitCacheFromConnectionTimeout() throws {
        for status in [InternetConnection.Status.unknown, .available(.great)] {
            try withClient(status: status) { client in
                try saveAccount(in: client.databaseContainer)
                XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: token()))
            }
        }
    }

    func testMemoryAndWrongScopeCannotAdmitCachedSession() throws {
        for scope in [ErmisLocalStorageScope.inMemory, .user("other-user")] {
            try withClient(scope: scope) { client in
                try saveAccount(in: client.databaseContainer)
                XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: token()))
            }
        }
    }

    func testServerAuthenticationAndGenericFailuresRemainFailuresWhileOffline() throws {
        try withClient { client in
            try saveAccount(in: client.databaseContainer)
            let server = NSError(domain: "server-fixture", code: 401)
            let transportTimeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            for error in [ClientError.ConnectionNotSuccessful(with: server),
                                 ClientError.ConnectionNotSuccessful(with: transportTimeout),
                                 ClientError.InvalidToken(), ClientError.RefreshTokenExpired()] as [Error] {
                XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: error, token: token()))
            }
        }
    }

    func testKnownOfflineTransportFailureMayReadOnlyItsCachedAccount() throws {
        try withClient { client in
            try saveAccount(in: client.databaseContainer)
            let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            XCTAssertTrue(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(with: offline), token: token()))
            XCTAssertNotEqual(client.connectionStatus, .connected)
        }
    }

    func testProductionWrappedOfflineSocketFailureCanReadCache() throws {
        try withClient { client in
            try saveAccount(in: client.databaseContainer)
            let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            let socketError = ClientError.WebSocket(with: WebSocketEngineError(error: offline))
            let connectionError = ClientError.ConnectionNotSuccessful(with: socketError)
            XCTAssertTrue(connectionError.isOffline)
            XCTAssertTrue(client.canReadCachedSession(afterConnectionFailure: connectionError, token: token()))
            XCTAssertNotEqual(client.connectionStatus, .connected)
        }
    }

    func testWrappedServerTimeoutAndUnrelatedAuthOfflineErrorsRemainBlocked() throws {
        try withClient { client in
            try saveAccount(in: client.databaseContainer)
            let server = NSError(domain: "server-fixture", code: 401)
            let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            for cause in [ClientError.WebSocket(with: server),
                          ClientError.WebSocket(with: WebSocketEngineError(error: timeout)),
                          ClientError.InvalidToken(with: offline)] {
                let error = ClientError.ConnectionNotSuccessful(with: cause)
                XCTAssertFalse(error.isOffline)
                XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: error, token: token()))
            }
        }
    }

    func testActualMemoryFallbackUnderUserScopeCannotQualifyAsDiskCache() throws {
        try withClient(memoryStoreFallback: true) { client in
            try saveAccount(in: client.databaseContainer)
            let store = try XCTUnwrap(client.databaseContainer.persistentStoreCoordinator.persistentStores.first)
            XCTAssertEqual(store.type, NSSQLiteStoreType)
            XCTAssertEqual(store.url?.path, "/dev/null")
            XCTAssertFalse(client.canReadCachedSession(afterConnectionFailure: ClientError.ConnectionNotSuccessful(), token: token()))
        }
    }

    func testOfflineClassificationDoesNotInferOfflineFromTimeoutOrMissingCause() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(ClientError.ConnectionNotSuccessful(with: offline).isOffline)
        XCTAssertTrue(ClientError.ConnectionNotSuccessful(with: WebSocketEngineError(error: offline)).isOffline)
        XCTAssertFalse(ClientError.ConnectionNotSuccessful().isOffline)
        XCTAssertFalse(ClientError.ConnectionNotSuccessful(with: ClientError.WaiterTimeout()).isOffline)
    }
}
