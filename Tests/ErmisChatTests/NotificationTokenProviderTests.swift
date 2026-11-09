import Foundation
import XCTest

@testable import ErmisChat

final class NotificationTokenProviderTests: XCTestCase {
    private func configuration(namespace: String?) throws -> ErmisClientConfig {
        var config = ErmisClientConfig(
            apiKeyString: "fixture-key",
            endpointEnviroment: .init(baseURL: try XCTUnwrap(URL(string: "https://example.invalid"))),
            isErmis: false
        )
        config.localStorageNamespace = namespace
        return config
    }

    func testScopedNotificationStateDoesNotImportOverwriteOrClearOriginal() throws {
        let original = UserDefaults.standard
        let keys = ["fcmToken", "deviceToken"]
        let previous = keys.map { original.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { original.set(value, forKey: key) }
                else { original.removeObject(forKey: key) }
            }
        }
        original.set("original-fcm-fixture", forKey: keys[0])
        original.set("original-device-fixture", forKey: keys[1])

        let configA = try configuration(namespace: "notification-a-" + UUID().uuidString)
        let configB = try configuration(namespace: "notification-b-" + UUID().uuidString)
        defer {
            for config in [configA, configB] {
                keys.forEach { config.namespacedUserDefaults?.removeObject(forKey: $0) }
            }
        }
        let first = DefaultNotificationTokenProvider(config: configA)
        XCTAssertNil(first.fcmToken)
        XCTAssertNil(first.deviceToken)
        first.fcmToken = "qa-a-fcm-fixture"
        first.deviceToken = "qa-a-device-fixture"

        let reopened = DefaultNotificationTokenProvider(config: configA)
        let other = DefaultNotificationTokenProvider(config: configB)
        XCTAssertEqual(reopened.fcmToken, "qa-a-fcm-fixture")
        XCTAssertEqual(reopened.deviceToken, "qa-a-device-fixture")
        XCTAssertNil(other.fcmToken)
        XCTAssertNil(other.deviceToken)
        reopened.fcmToken = nil
        reopened.deviceToken = nil
        XCTAssertEqual(original.string(forKey: keys[0]), "original-fcm-fixture")
        XCTAssertEqual(original.string(forKey: keys[1]), "original-device-fixture")
    }

    func testUnscopedAndEmptyNamespaceRetainProductionDefaults() throws {
        for namespace in [nil, ""] as [String?] {
            let provider = DefaultNotificationTokenProvider(config: try configuration(namespace: namespace))
            XCTAssertEqual(provider.fcmToken, UserDefaults.standard.string(forKey: "fcmToken"))
            XCTAssertEqual(provider.deviceToken, UserDefaults.standard.string(forKey: "deviceToken"))
        }
    }
}
