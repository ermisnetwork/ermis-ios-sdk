import XCTest
import Security
@testable import ErmisChat

final class RecoveryKeyIsolationTests: XCTestCase {
    func testProtectCreatesStashButOpenNeverRecreatesLostKey() throws {
        let namespace = "fixture-\(UUID())", service = "io.ermis.archive.\(namespace)"
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary) }
        let store = E2eeRecoveryKeyStore(namespace: namespace), secret = Data([1, 2, 3])
        let protected = try store.protect(secret, purpose: "fixture")
        XCTAssertEqual(try store.open(protected, purpose: "fixture"), secret)
        XCTAssertThrowsError(try store.open(protected, purpose: "foreign"))
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "stash"] as CFDictionary)
        XCTAssertThrowsError(try store.open(protected, purpose: "fixture"))
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "stash", kSecReturnData: true] as CFDictionary
        XCTAssertEqual(SecItemCopyMatching(query, nil), errSecItemNotFound)
    }
    func testUnlockSurvivesReopenIsolatesAccountsAndRetainsMissingMarker() throws {
        let namespace = "fixture-\(UUID())", other = "fixture-\(UUID())"
        defer { for name in [namespace, other] { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "io.ermis.archive.\(name)"] as CFDictionary) } }
        let store = E2eeRecoveryKeyStore(namespace: namespace), secret = Data([1, 2, 3])
        XCTAssertFalse(try store.hadUnlock()); try store.saveUnlock(secret)
        XCTAssertEqual(try E2eeRecoveryKeyStore(namespace: namespace).loadUnlock(), secret)
        XCTAssertNil(try E2eeRecoveryKeyStore(namespace: other).loadUnlock())
        try store.clearUnlock(); XCTAssertNil(try store.loadUnlock()); XCTAssertTrue(try store.hadUnlock())
    }
}
