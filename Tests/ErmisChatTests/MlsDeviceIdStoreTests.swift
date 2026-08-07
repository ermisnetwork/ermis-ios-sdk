import XCTest
@testable import ErmisChat

final class MlsDeviceIdStoreTests: XCTestCase {
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

        let store = MlsDeviceIdStore(defaults: scoped, legacyDefaults: legacy)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-legacy")
        XCTAssertEqual(
            (scoped.dictionary(forKey: MlsDeviceIdStore.deviceIdKey) as? [String: String])?["alice"],
            "ios-legacy"
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
        let store = MlsDeviceIdStore(defaults: scoped, legacyDefaults: legacy)

        XCTAssertEqual(store.canonicalDeviceId(for: "alice"), "ios-canonical")
        XCTAssertTrue(store.owns(deviceId: "ios-canonical", for: "alice"))
        XCTAssertTrue(store.owns(deviceId: "ios-legacy", for: "alice"))
        XCTAssertFalse(store.owns(deviceId: "ios-bob", for: "alice"))
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
        let store = MlsDeviceIdStore(defaults: scoped, legacyDefaults: scoped)

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
