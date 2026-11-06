import XCTest
import Darwin
import CryptoKit
import open_mls_ios
@testable import ErmisChat

@_silgen_name("flock")
private func testProviderFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class MlsInitializationOwnershipTests: XCTestCase {
    private final class SecureStore: MlsDeviceIdSecureStoring {
        enum Failure: Error { case unavailable }
        var values: [String: String] = [:]
        var unavailable = false
        func load(userId: String) throws -> String? { if unavailable { throw Failure.unavailable }; return values[userId] }
        func save(deviceId: String, userId: String) throws { if unavailable { throw Failure.unavailable }; values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }
    private func fixture() throws -> (URL, UserDefaults, SecureStore, MlsDeviceIdStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-owner-" + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "native-owner-" + UUID().uuidString))
        let secure = SecureStore()
        return (root, defaults, secure, MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure))
    }
    private func client(_ root: URL, _ defaults: UserDefaults, _ devices: MlsDeviceIdStore) -> MlsClient {
        MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false)
    }
    private func identityHash(_ client: MlsClient) throws -> String {
        SHA256.hash(data: try XCTUnwrap(client.identity).toBytes()).map { String(format: "%02x", $0) }.joined()
    }
    func testRepeatedSameAccountSetupPreservesNativeOwnerObjects() throws {
        let (root, defaults, _, devices) = try fixture()
        let first = client(root, defaults, devices)
        try first.setup(with: "owner-fixture")
        let provider = try XCTUnwrap(first.provider), identity = try XCTUnwrap(first.identity)
        let device = first.currentDeviceId
        try first.setup(with: "owner-fixture")
        XCTAssertTrue(first.provider === provider, "Refresh/startup callbacks must reuse the live provider owner")
        XCTAssertTrue(first.identity === identity, "A repeated token callback cannot retire the active signing owner")
        XCTAssertEqual(first.currentDeviceId, device)
    }
    func testSecondOwnerOfSamePrivateScopeFailsClosedUntilFirstReleases() throws {
        let (root, defaults, _, devices) = try fixture()
        let first = client(root, defaults, devices), second = client(root, defaults, devices)
        let namespace = SHA256.hash(data: Data("owner-fixture".utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = root.appendingPathComponent("mls", isDirectory: true).appendingPathComponent("ermis_mls_" + namespace + ".db")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let beforePathHash = SHA256.hash(data: Data(destination.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
        let beforePort = try MlsProviderScopeLease.ownershipPort(databaseURL: destination)
        try first.setup(with: "owner-fixture")
        let afterPathHash = SHA256.hash(data: Data(destination.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
        print("QA_LEASE_NAMESPACE before_hash=\(beforePathHash) after_hash=\(afterPathHash) before_port=\(beforePort) after_port=\(try MlsProviderScopeLease.ownershipPort(databaseURL: destination))")
        XCTAssertEqual(beforePort, try MlsProviderScopeLease.ownershipPort(databaseURL: destination), "SQLite creation must not change the kernel ownership namespace")
        let fingerprint = try identityHash(first), device = first.currentDeviceId
        XCTAssertThrowsError(try second.setup(with: "owner-fixture"))
        XCTAssertFalse(second.hasSetup)
        XCTAssertEqual(try identityHash(first), fingerprint)
        try first.reset()
        try second.setup(with: "owner-fixture")
        XCTAssertEqual(try identityHash(second), fingerprint)
        XCTAssertEqual(second.currentDeviceId, device)
    }
    func testDistinctAccountScopesCanRemainOwnedIndependently() throws {
        let (root, defaults, _, devices) = try fixture()
        let first = client(root, defaults, devices), second = client(root, defaults, devices)
        try first.setup(with: "owner-fixture-a")
        try second.setup(with: "owner-fixture-b")
        XCTAssertTrue(first.hasSetup && second.hasSetup)
        XCTAssertNotEqual(try identityHash(first), try identityHash(second))
    }
    func testProtectedBindingFailurePreservesPrivateIdentityForUnlockedRetry() throws {
        let (root, defaults, secure, devices) = try fixture()
        let first = client(root, defaults, devices)
        try first.setup(with: "owner-fixture")
        let fingerprint = try identityHash(first), device = first.currentDeviceId
        try first.reset()
        secure.unavailable = true
        let second = client(root, defaults, devices)
        XCTAssertThrowsError(try second.setup(with: "owner-fixture"))
        XCTAssertFalse(second.hasSetup)
        secure.unavailable = false
        try second.setup(with: "owner-fixture")
        XCTAssertEqual(try identityHash(second), fingerprint)
        XCTAssertEqual(second.currentDeviceId, device)
    }
    func testBoundProviderMissingIdentityFailsWithoutCreatingReplacementSigner() throws {
        let (root, defaults, secure, devices) = try fixture()
        let first = client(root, defaults, devices)
        let user = "owner-missing-private-identity"
        try first.setup(with: user)
        let device = first.currentDeviceId
        let namespace = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        let database = root.appendingPathComponent("mls/ermis_mls_" + namespace + ".db")
        let binding = try XCTUnwrap(MlsInstallationBindingStore(url: database).load())
        try first.reset()
        // Isolated corruption fixture: remove only this fixture's native identity. Its
        // durable installation binding remains proof that this is not a fresh provider.
        do { let provider = try Provider.newWithPath(dbPath: database.path); try provider.deleteIdentity() }
        let reopened = client(root, defaults, devices)
        XCTAssertThrowsError(try reopened.setup(with: user))
        XCTAssertFalse(reopened.hasSetup)
        let inspected = try Provider.newWithPath(dbPath: database.path)
        XCTAssertNil(try inspected.loadIdentity(), "Failed setup must not persist a new private signer")
        XCTAssertEqual(try MlsInstallationBindingStore(url: database).load(), binding)
        XCTAssertEqual(secure.values[user], device)
    }
    func testProviderOwnershipDoesNotRetainAFileLockDuringSuspension() throws {
        let (root, _, _, _) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("provider.db")
        let lease = try MlsProviderScopeLease(databaseURL: database)
        let handle = Darwin.open(database.appendingPathExtension("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(handle, 0)
        defer { Darwin.close(handle) }
        try withExtendedLifetime(lease) {
            // Persistent flock on an AppGroup file causes iOS DEAD10CC at suspension.
            // Ownership must remain exclusive after the short bootstrap lock is released.
            XCTAssertEqual(testProviderFlock(handle, LOCK_EX | LOCK_NB), 0)
            _ = testProviderFlock(handle, LOCK_UN)
            XCTAssertThrowsError(try MlsProviderScopeLease(databaseURL: database))
        }
    }

    #if !os(iOS) || targetEnvironment(simulator)
    func testOwnershipSocketRejectsForeignFileWithoutDeletingIt() throws {
        let (root, _, _, _) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("provider.db")
        let endpoint = try MlsProviderScopeLease.ownershipSocketURL(databaseURL: database)
        let bytes = Data("foreign-fixture-must-survive".utf8)
        try bytes.write(to: endpoint, options: .withoutOverwriting)
        XCTAssertThrowsError(try MlsProviderScopeLease(databaseURL: database))
        XCTAssertEqual(try Data(contentsOf: endpoint), bytes)
    }
    #endif

    #if os(iOS) && !targetEnvironment(simulator)
    func testBoundOnlyLoopbackEndpointKeepsExclusiveOwnershipAndReleases() throws {
        let (root, _, _, _) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("provider.db")
        var owner: MlsProviderScopeLease? = try MlsProviderScopeLease(databaseURL: database)
        XCTAssertNotNil(owner)
        for _ in 0..<12 {
            XCTAssertThrowsError(try MlsProviderScopeLease(databaseURL: database)) { error in
                XCTAssertEqual(error as? MlsProviderScopeLeaseError, .alreadyOwned)
            }
        }
        owner = nil
        XCTAssertNoThrow(try MlsProviderScopeLease(databaseURL: database))
    }
    #endif

}
