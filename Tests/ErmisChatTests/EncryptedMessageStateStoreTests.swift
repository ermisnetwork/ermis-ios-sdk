// Copyright 2026 Ermis Inc.

import XCTest
import CoreData
import open_mls_ios
@testable import ErmisChat

final class EncryptedMessageStateStoreTests: XCTestCase {
    func testStateIsCipherRouteAndMessageBoundAndClearsAfterSuccess() {
        let store = EncryptedMessageStateStore()
        let key = EncryptedMessageStateStore.Key(cid: "team:a", id: "message", ciphertext: Data([1]))
        XCTAssertEqual(store.state(for: key), .encrypted)
        store.begin(key)
        XCTAssertEqual(store.state(for: key), .decrypting)
        store.set(.failed, for: key)
        store.begin(key)
        XCTAssertEqual(store.state(for: key), .failed)
        for other in [EncryptedMessageStateStore.Key(cid: "team:b", id: "message", ciphertext: Data([1])),
                      .init(cid: "team:a", id: "other", ciphertext: Data([1])),
                      .init(cid: "team:a", id: "message", ciphertext: Data([2]))] {
            XCTAssertEqual(store.state(for: other), .encrypted)
        }
        store.set(.encrypted, for: key)
        XCTAssertEqual(store.state(for: key), .encrypted)
    }

    func testDatabaseOwnersDoNotShareFailures() {
        let model = NSManagedObjectModel()
        let first = NSPersistentStoreCoordinator(managedObjectModel: model)
        let other = NSPersistentStoreCoordinator(managedObjectModel: model)
        let key = EncryptedMessageStateStore.Key(cid: "team:a", id: "message", ciphertext: Data([1]))
        first.encryptedMessageStates.set(.failed, for: key)
        XCTAssertTrue(first.encryptedMessageStates === first.encryptedMessageStates)
        XCTAssertEqual(other.encryptedMessageStates.state(for: key), .encrypted)
    }

    func testStoreEvictsOnlyBoundedMetadata() {
        let store = EncryptedMessageStateStore(capacity: 2)
        let keys = (1...3).map { EncryptedMessageStateStore.Key(cid: "team:a", id: String($0), ciphertext: Data([1])) }
        keys.forEach { store.set(.failed, for: $0) }
        XCTAssertEqual(store.state(for: keys[0]), .encrypted)
        XCTAssertEqual(store.state(for: keys[2]), .failed)
    }

    func testPendingProtocolAndStorageAreNotCryptoFailures() {
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: MlsError.InvalidMessage(message: "fixture"), nativeAtExpectedEpoch: false), .encrypted)
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: MlsError.StorageError(message: "fixture"), nativeAtExpectedEpoch: true), .encrypted)
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: MlsError.GroupNotFound(message: "fixture"), nativeAtExpectedEpoch: true), .encrypted)
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: URLError(.notConnectedToInternet), nativeAtExpectedEpoch: true), .encrypted)
    }

    func testActualCryptoAndAuthenticatedPayloadFailuresHaveDistinctCopyState() {
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: MlsError.InvalidMessage(message: "fixture"), nativeAtExpectedEpoch: true), .failed)
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: MlsError.MessageAlreadyConsumed(message: "fixture"), nativeAtExpectedEpoch: true), .unavailable)
        XCTAssertEqual(EncryptedMessageFailurePresentation.state(for: E2eeMessageAADError.authenticatedMetadataMismatch, nativeAtExpectedEpoch: true), .failed)
    }
}
