import Foundation
import XCTest
import open_mls_ios
@testable import ErmisChat

/// Public signed GroupInfo only. No provider, identity, token or private KeyPackage fixture.
final class MlsJoinTreePolicyTests: XCTestCase {
    // Preserved expired tree: strict Verify must fail; checked AllowExpired may join.
    // SHA256: ba8d753f8bc58e2245c9340c4ecb48634881ff0ddc79cc26a27de03fb787f0cd
    private let expiredGroupInfo = Data(base64Encoded: "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")!

    private final class SecureStore: MlsDeviceIdSecureStoring {
        var values: [String: String] = [:]
        func load(userId: String) throws -> String? { values[userId] }
        func save(deviceId: String, userId: String) throws { values[userId] = deviceId }
        func remove(userId: String) throws { values.removeValue(forKey: userId) }
    }

    private func fixture(allowExpired: Bool = false) throws -> (MlsClient, URL, UserDefaults) {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("join-policy-" + id)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "join-policy-" + id))
        let devices = MlsDeviceIdStore(defaults: defaults, legacyDefaults: defaults, secureStore: SecureStore())
        let client = MlsClient(storageFolderURL: root, deviceIdStore: devices, userDefaults: defaults, importLegacyStorage: false,
                               allowExpiredJoinTreeLeaves: allowExpired)
        try client.setup(with: "join-policy-" + id)
        return (client, root, defaults)
    }

    func testExpiredTreePolicyReachesBothExternalJoinConsumersAndRejectsInvalidSignature() throws {
        for isolated in [false, true] {
            let (strict, strictRoot, strictDefaults) = try fixture()
            let (checked, checkedRoot, checkedDefaults) = try fixture(allowExpired: true)
            defer {
                try? strict.reset(); try? checked.reset()
                try? FileManager.default.removeItem(at: strictRoot)
                try? FileManager.default.removeItem(at: checkedRoot)
                strictDefaults.removePersistentDomain(forName: strictRoot.lastPathComponent)
                checkedDefaults.removePersistentDomain(forName: checkedRoot.lastPathComponent)
            }
            func join(_ client: MlsClient, _ data: Data, _ suffix: String) throws -> ExternalJoinResult {
                if isolated {
                    return try client.externalJoinIsolated(cid: "team:policy-" + suffix, generation: 0,
                                                           groupInfo: data, expectedGroupId: nil)
                }
                return try client.externalJoin(groupInfo: data)
            }
            XCTAssertFalse(strict.allowExpiredJoinTreeLeaves)
            XCTAssertThrowsError(try join(strict, expiredGroupInfo, "strict")) { error in
                guard case MlsError.KeyPackageExpired = error else { return XCTFail("Expected strict tree expiry rejection") }
            }
            let joined = try join(checked, expiredGroupInfo, "checked")
            XCTAssertEqual(joined.group.epoch(), 9)
            var corrupt = expiredGroupInfo
            corrupt[corrupt.count - 1] ^= 1
            XCTAssertThrowsError(try join(checked, corrupt, "bad-signature")) { error in
                if case MlsError.KeyPackageExpired = error { XCTFail("Opt-in did not reach native validation") }
            }
        }
    }

    func testExpiredWelcomeTreeUsesTheConfiguredPolicy() throws {
        let (producer, producerRoot, producerDefaults) = try fixture(allowExpired: true)
        let (strict, strictRoot, strictDefaults) = try fixture()
        let (checked, checkedRoot, checkedDefaults) = try fixture(allowExpired: true)
        defer {
            for (client, root, defaults) in [(producer, producerRoot, producerDefaults), (strict, strictRoot, strictDefaults), (checked, checkedRoot, checkedDefaults)] {
                try? client.reset()
                try? FileManager.default.removeItem(at: root)
                defaults.removePersistentDomain(forName: root.lastPathComponent)
            }
        }
        let joined = try producer.externalJoin(groupInfo: expiredGroupInfo)
        let provider = try XCTUnwrap(producer.provider), identity = try XCTUnwrap(producer.identity)
        if joined.group.hasPendingCommit() { try joined.group.mergePendingCommit(provider: provider) }
        let strictProvider = try XCTUnwrap(strict.provider), checkedProvider = try XCTUnwrap(checked.provider)
        let strictIdentity = try XCTUnwrap(strict.identity), checkedIdentity = try XCTUnwrap(checked.identity)
        let bundle = try joined.group.addMembers(provider: provider, sender: identity, newMembers: [
            strictIdentity.keyPackage(provider: strictProvider), checkedIdentity.keyPackage(provider: checkedProvider)
        ])
        try joined.group.mergePendingCommit(provider: provider)
        let welcome = try XCTUnwrap(bundle.welcome)
        XCTAssertThrowsError(try strict.joinWithWelcome(cid: "team:policy-strict-welcome", welcome: welcome,
                                                      ratchetTree: joined.group.exportRatchetTree())) { error in
            guard case MlsError.KeyPackageExpired = error else { return XCTFail("Expected strict Welcome tree expiry rejection") }
        }
        let group = try checked.joinWithWelcome(cid: "team:policy-checked-welcome", welcome: welcome,
                                                ratchetTree: joined.group.exportRatchetTree())
        XCTAssertEqual(group.groupId(), joined.group.groupId())
        XCTAssertEqual(group.epoch(), joined.group.epoch())
    }
}
