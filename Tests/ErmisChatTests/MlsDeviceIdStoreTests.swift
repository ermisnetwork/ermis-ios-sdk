import XCTest
@testable import ErmisChat

final class MlsDeviceIdStoreTests: XCTestCase {
    private final class SecureStore: MlsDeviceIdSecureStoring {
        enum Failure: Error { case unavailable }

        var values: [UserId: String] = [:]
        var loadError: Error?
        var saveError: Error?
        var readBackOverride: String?
        var didSave = false

        func load(userId: UserId) throws -> String? {
            if let loadError { throw loadError }
            if didSave, let readBackOverride { return readBackOverride }
            return values[userId]
        }

        func save(deviceId: String, userId: UserId) throws {
            if let saveError { throw saveError }
            values[userId] = deviceId
            didSave = true
        }

        func remove(userId: UserId) throws {
            values.removeValue(forKey: userId)
        }
    }

    func testImportsLegacyStandardIdIntoScopedStore() throws {
        let scopedSuite = "io.ermis.tests.device.scoped.\(UUID().uuidString)"
        let legacySuite = "io.ermis.tests.device.legacy.\(UUID().uuidString)"
        let scoped = try XCTUnwrap(UserDefaults(suiteName: scopedSuite))
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer {
            scoped.removePersistentDomain(forName: scopedSuite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
        legacy.set(["alice": "ios-legacy"], forKey: MlsDeviceIdStore.deviceIdKey)

        let secure = SecureStore()
        let store = MlsDeviceIdStore(defaults: scoped, legacyDefaults: legacy, secureStore: secure)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-legacy")
        XCTAssertEqual(secure.values["alice"], "ios-legacy")
        XCTAssertEqual(
            (scoped.dictionary(forKey: MlsDeviceIdStore.migrationMarkerKey) as? [String: Bool])?["alice"],
            true
        )
        XCTAssertEqual(
            (legacy.dictionary(forKey: MlsDeviceIdStore.deviceIdKey) as? [String: String])?["alice"],
            "ios-legacy",
            "The rollback source remains available during the support window."
        )
    }

    func testScopedIdIsCanonicalAndDifferentLegacyIdIsReceiveOnlyAlias() throws {
        let scopedSuite = "io.ermis.tests.device.scoped.\(UUID().uuidString)"
        let legacySuite = "io.ermis.tests.device.legacy.\(UUID().uuidString)"
        let scoped = try XCTUnwrap(UserDefaults(suiteName: scopedSuite))
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer {
            scoped.removePersistentDomain(forName: scopedSuite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
        scoped.set(["alice": "ios-canonical"], forKey: MlsDeviceIdStore.deviceIdKey)
        legacy.set(["alice": "ios-legacy", "bob": "ios-bob"], forKey: MlsDeviceIdStore.deviceIdKey)
        let secure = SecureStore()
        secure.values["alice"] = "ios-keychain"
        let store = MlsDeviceIdStore(defaults: scoped, legacyDefaults: legacy, secureStore: secure)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-keychain")
        XCTAssertTrue(store.owns(deviceId: "ios-keychain", for: "alice"))
        XCTAssertTrue(store.owns(deviceId: "ios-canonical", for: "alice"))
        XCTAssertTrue(store.owns(deviceId: "ios-legacy", for: "alice"))
        XCTAssertFalse(store.owns(deviceId: "ios-bob", for: "alice"))
    }

    func testUnavailableKeychainKeepsLegacyIdAndDoesNotGenerateReplacement() throws {
        let suite = "io.ermis.tests.device.locked.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["alice": "ios-legacy"], forKey: MlsDeviceIdStore.deviceIdKey)
        let secure = SecureStore()
        secure.loadError = SecureStore.Failure.unavailable
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-legacy")
        XCTAssertTrue(secure.values.isEmpty)
        XCTAssertTrue(store.owns(deviceId: "ios-legacy", for: "alice"))
        XCTAssertFalse(store.owns(deviceId: "ios-other", for: "alice"))
        XCTAssertNil(
            (defaults.dictionary(forKey: MlsDeviceIdStore.migrationMarkerKey) as? [String: Bool])?["alice"]
        )
    }

    func testUnavailableKeychainAfterMigrationFailsClosedWithoutReusingRestoredId() throws {
        let suite = "io.ermis.tests.device.locked-migrated.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["alice": "ios-restored"], forKey: MlsDeviceIdStore.deviceIdKey)
        defaults.set(["alice": true], forKey: MlsDeviceIdStore.migrationMarkerKey)
        let secure = SecureStore()
        secure.loadError = SecureStore.Failure.unavailable
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure)

        XCTAssertNil(store.canonicalDeviceId(for: "alice"))
        XCTAssertTrue(secure.values.isEmpty)
        XCTAssertFalse(store.owns(deviceId: "ios-restored", for: "alice"))
    }

    func testFailedWriteReadBackKeepsLegacyAndRetriesMigration() throws {
        let suite = "io.ermis.tests.device.readback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["alice": "ios-legacy"], forKey: MlsDeviceIdStore.deviceIdKey)
        let secure = SecureStore()
        secure.readBackOverride = "wrong-value"
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-legacy")
        XCTAssertNil(
            (defaults.dictionary(forKey: MlsDeviceIdStore.migrationMarkerKey) as? [String: Bool])?["alice"]
        )
    }

    func testMissingKeychainAfterCompletedMigrationCreatesNewInstallationId() throws {
        let suite = "io.ermis.tests.device.new-install.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["alice": "ios-old"], forKey: MlsDeviceIdStore.deviceIdKey)
        defaults.set(["alice": true], forKey: MlsDeviceIdStore.migrationMarkerKey)
        let secure = SecureStore()
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure)

        let newId = try XCTUnwrap(store.canonicalDeviceId(for: "alice"))
        XCTAssertTrue(newId.hasPrefix("ios-"))
        XCTAssertNotEqual(newId, "ios-old")
        XCTAssertEqual(secure.values["alice"], newId)
        XCTAssertFalse(
            store.owns(deviceId: "ios-old", for: "alice"),
            "A restored ID belongs to the previous MLS device, not the new installation."
        )
        XCTAssertNil(
            (defaults.dictionary(forKey: MlsDeviceIdStore.deviceIdKey) as? [String: String])?["alice"]
        )
    }

    func testMigratesMultipleUsersToIndependentSecureItems() throws {
        let suite = "io.ermis.tests.device.multi-user.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["alice": "ios-alice", "bob": "ios-bob"], forKey: MlsDeviceIdStore.deviceIdKey)
        let secure = SecureStore()
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-alice")
        XCTAssertEqual(store.canonicalDeviceId(for: "bob"), "ios-bob")
        XCTAssertEqual(secure.values, ["alice": "ios-alice", "bob": "ios-bob"])
    }

    func testLogoutLoginKeepsSecureDeviceIdUntilExplicitPurge() throws {
        let suite = "io.ermis.tests.device.login.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secure = SecureStore()
        let store = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: secure)

        let first = try XCTUnwrap(store.canonicalDeviceId(for: "alice"))
        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), first)
        store.removeUser("alice")
        let afterPurge = try XCTUnwrap(store.canonicalDeviceId(for: "alice"))
        XCTAssertNotEqual(afterPurge, first)
    }

    func testMlsHttpAndWebSocketUseTheSameCanonicalDeviceId() throws {
        let scopedSuite = "io.ermis.tests.device.integration.\(UUID().uuidString)"
        let scoped = try XCTUnwrap(UserDefaults(suiteName: scopedSuite))
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MlsDeviceIdStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        defer {
            scoped.removePersistentDomain(forName: scopedSuite)
            try? FileManager.default.removeItem(at: storageURL)
        }
        scoped.set(["alice": "ios-canonical"], forKey: MlsDeviceIdStore.deviceIdKey)
        let store = MlsDeviceIdStore(
            defaults: scoped,
            legacyDefaults: scoped,
            secureStore: SecureStore()
        )

        let mlsClient = MlsClient(storageFolderURL: storageURL, deviceIdStore: store)
        try mlsClient.setup(with: "alice")
        XCTAssertEqual(mlsClient.currentDeviceId, "ios-canonical")

        let encoder = DefaultRequestEncoder(
            baseURL: URL(string: "https://bellboy.example")!,
            authURL: URL(string: "https://auth.example")!,
            stickerURL: URL(string: "https://stickers.example")!,
            apiKey: APIKey("test-key")
        )
        encoder.deviceIdStore = store
        let httpEndpoint = Endpoint<EmptyResponse>(
            path: .sync,
            method: .get,
            query: ["user_id": "alice"],
            needDeviceId: true,
            needToken: false
        )
        let request = try encoder.encodeRequest(for: httpEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-ID"), "ios-canonical")

        let webSocketEndpoint: Endpoint<EmptyResponse> = .webSocketConnect(
            userInfo: UserInfo(id: "alice"),
            token: nil,
            deviceId: try XCTUnwrap(mlsClient.currentDeviceId),
            apiKey: "test-key"
        )
        let queryData = try JSONEncoder.ermis.encode(AnyEncodable(webSocketEndpoint.query!))
        let query = try XCTUnwrap(
            JSONSerialization.jsonObject(with: queryData) as? [String: String]
        )
        XCTAssertEqual(query["device_id"], "ios-canonical")
    }
}
