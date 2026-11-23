import XCTest
import CryptoKit
@testable import ErmisChat

final class MlsFirstConnectionBindingTests: XCTestCase {
    private final class Monitor: InternetConnectionMonitor {
        weak var delegate: InternetConnectionDelegate?
        var status: InternetConnection.Status = .unavailable
        func start() {}
        func stop() {}
    }
    private final class AuthenticationObserver: AuthenticationRepositoryDelegate {
        var firstConnection: (() -> Void)?
        func didFinishSettingUpAuthenticationEnvironment(for state: EnvironmentState) {
            if case .firstConnection = state { firstConnection?() }
        }
        func logOutUser(completion: @escaping () -> Void) { completion() }
    }

    func testFreshLoginPublishesTokenAndFirstConnectionOnlyAfterNativeBindingIsReady() throws {
        let id = UUID().uuidString
        let user = "kp-login-fixture-" + id
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(user)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = ErmisClientConfig(apiKeyString: "fixture", endpointEnviroment: .init(baseURL: URL(string: "https://login.invalid")!), isErmis: false)
        config.localStorageFolderURL = root
        config.localStorageNamespace = user
        config.localStorageScope = .user(user)
        var environment = ErmisClient.Environment()
        environment.monitor = Monitor()
        environment.backgroundTaskSchedulerBuilder = { nil }
        let client = ErmisClient(config: config, clientId: "fixture", projectId: "project", rootProjectId: "project", chainId: 1,
            environment: environment, notificationTokenProvider: DefaultNotificationTokenProvider(),
            factory: ErmisClientFactory(config: config, environment: environment))
        defer {
            try? client.mlsClient.reset()
            client.mlsClient.deviceIdStore.removeUser(user)
            for context in client.databaseContainer.allContext { context.performAndWait { context.reset() } }
            for store in client.databaseContainer.persistentStoreCoordinator.persistentStores {
                try? client.databaseContainer.persistentStoreCoordinator.remove(store)
            }
            let name = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
            config.namespacedUserDefaults?.removePersistentDomain(forName: "network.ermis.chat.scopes." + name)
            try? FileManager.default.removeItem(at: root)
        }
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !client.databaseContainer.persistentStoreCoordinator.persistentStores.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let observer = AuthenticationObserver()
        client.authenticationRepository.delegate = observer
        var callbacks = 0
        observer.firstConnection = {
            callbacks += 1
            XCTAssertTrue(client.mlsClient.hasSetup, "First connection must not race provider/binding initialization")
            XCTAssertNotNil(client.mlsClient.provider)
            XCTAssertNotNil(client.mlsClient.identity)
            XCTAssertEqual(client.authenticationRepository.currentDeviceId, client.mlsClient.currentDeviceId)
        }
        let tokenDelivered = expectation(description: "queued auth delivered")
        client.authenticationRepository.provideToken { result in
            if case .failure = result { XCTFail("Fixture token must be delivered") }
            XCTAssertTrue(client.mlsClient.hasSetup, "Queued HTTP auth must not start before the native owner is bound")
            tokenDelivered.fulfill()
        }
        let token = Token(rawValue: "fixture", userId: user, clientId: "fixture", projectId: "project", chainId: 1, isErmis: false, expiration: nil)
        client.updateToken(token, userInfo: UserInfo(id: user))
        wait(for: [tokenDelivered], timeout: 2)
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(client.mlsClient.hasSetup)
        XCTAssertEqual(client.authenticationRepository.currentDeviceId, client.mlsClient.currentDeviceId)
    }
}
