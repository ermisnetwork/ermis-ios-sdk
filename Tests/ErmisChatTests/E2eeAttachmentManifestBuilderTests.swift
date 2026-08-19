//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeAttachmentManifestBuilderTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var keychain: ManifestBuilderKeychainStore!
    private var wrappingKeyStore: E2eeAttachmentWrappingKeyStore!

    override func setUpWithError() throws {
        defaultsSuiteName = "E2eeAttachmentManifestBuilderTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        keychain = ManifestBuilderKeychainStore()
        wrappingKeyStore = E2eeAttachmentWrappingKeyStore(
            keychain: keychain,
            defaults: defaults,
            access: .mainApp
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        wrappingKeyStore = nil
        keychain = nil
        defaults = nil
        defaultsSuiteName = nil
    }

    func testBuildsValidatedManifestOnlyAfterServiceCompletion() throws {
        let contentKey = Data((0..<32).map(UInt8.init))
        let noncePrefix = Data((32..<40).map(UInt8.init))
        let sealed = try wrappingKeyStore.seal(E2eeAttachmentSecretMaterial(
            contentKey: contentKey,
            noncePrefix: noncePrefix
        ))
        let attachmentId = UUID().uuidString
        let assetId = UUID().uuidString
        var asset = PendingE2eeAsset(
            attachmentId: attachmentId,
            assetId: assetId,
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: nil,
            ciphertextSize: UInt64(E2eeAttachmentFrameCryptoV1.emptyCiphertextSize),
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: sealed,
            frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
            plaintextSize: 0,
            plaintextSha256: String(repeating: "b", count: 64),
            display: ["name": .string("empty.bin")],
            uploadMode: .singlePut,
            uploadExpiresAt: Date().addingTimeInterval(600),
            taskIdentifier: nil,
            taskToken: nil,
            parts: []
        )
        asset.isUploaded = true
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "team:project:channel",
            phase: .finalizing,
            totalBytes: Int64(E2eeAttachmentFrameCryptoV1.emptyCiphertextSize)
        )
        attempt.assets = [asset]
        attempt.completionIntents = [
            .init(
                attachmentId: attachmentId,
                request: .init(completionLeaseId: UUID().uuidString, assets: nil),
                isServiceCompleted: true
            )
        ]

        let manifests = try E2eeAttachmentManifestBuilder(
            wrappingKeyStore: wrappingKeyStore
        ).buildCompletedManifests(for: attempt)

        let manifest = try XCTUnwrap(manifests.first)
        let manifestAsset = try XCTUnwrap(manifest.assets.first)
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(manifest.attachmentId, attachmentId)
        XCTAssertEqual(manifestAsset.assetId, assetId)
        XCTAssertEqual(manifestAsset.contentKey, contentKey.base64EncodedString())
        XCTAssertEqual(manifestAsset.noncePrefix, noncePrefix.base64EncodedString())
        XCTAssertEqual(manifestAsset.display?["name"], .string("empty.bin"))
        XCTAssertEqual(attempt.assets.first?.sealedSecret, sealed)
    }

    func testRejectsManifestBeforeServiceCompletionWithoutUnsealing() throws {
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "team:project:channel",
            phase: .finalizing
        )
        attempt.assets = []

        XCTAssertThrowsError(
            try E2eeAttachmentManifestBuilder(
                wrappingKeyStore: wrappingKeyStore
            ).buildCompletedManifests(for: attempt)
        ) { error in
            XCTAssertEqual(
                error as? E2eeAttachmentManifestBuilderError,
                .attachmentNotServiceCompleted
            )
        }
        XCTAssertEqual(keychain.loadCount, 0)
    }
}

private final class ManifestBuilderKeychainStore: E2eeAttachmentKeychainStoring {
    private let lock = NSLock()
    private var stored: Data?
    private(set) var loadCount = 0

    func load() throws -> Data? {
        lock.withLock {
            loadCount += 1
            return stored
        }
    }

    func addAtomically(_ data: Data) throws -> E2eeAttachmentKeychainAddResult {
        lock.withLock {
            guard stored == nil else { return .duplicate }
            stored = data
            return .inserted
        }
    }
}
