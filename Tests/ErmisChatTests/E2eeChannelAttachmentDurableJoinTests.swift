//
// Copyright 2026 Ermis Inc.
//

import CoreData
@testable import ErmisChat
import XCTest

final class E2eeChannelAttachmentDurableJoinTests: XCTestCase {
    private let cid = ChannelId(type: .messaging, id: "durable-channel-info")

    func testDurablePageJoinRequiresExactMessageAttachmentCidAndAssetSet() async throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        let messageA = "message-a"
        let messageB = "message-b"
        let missingMessage = "message-missing"
        let corruptMessage = "message-corrupt"
        let attachmentA = "11111111-1111-4111-8111-111111111111"
        let attachmentB = "22222222-2222-4222-8222-222222222222"
        let manifestA = makeManifest(
            attachmentId: attachmentA,
            originalAssetId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
            previewAssetId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2",
            fileSuffix: "a"
        )
        let manifestB = makeManifest(
            attachmentId: attachmentB,
            originalAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1",
            previewAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2",
            fileSuffix: "b"
        )
        try database.writeAndWait { session in
            try session.saveMessageDecrypt(
                payload: makePayload(manifestA),
                messageId: messageA,
                ciphertextHash: Data([1])
            )
            try session.saveMessageDecrypt(
                payload: makePayload(manifestB),
                messageId: messageB,
                ciphertextHash: Data([2])
            )
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            let corrupt = MessageDecryptDTO.loadOrCreate(
                messageId: corruptMessage,
                context: context
            )
            corrupt.text = ""
            corrupt.attachmentsData = Data("not-valid-json".utf8)
            corrupt.ciphertextHash = Data([3])
        }

        let payloads = try await E2eeChannelAttachmentDurableManifestStore.loadPayloads(
            messageIds: [messageA, messageB, missingMessage, corruptMessage],
            databaseContainer: database
        )
        XCTAssertEqual(Set(payloads.keys), Set([messageA, messageB]))

        let valid = makeProjection(messageId: messageA, manifest: manifestA)
        let wrongMessage = makeProjection(messageId: messageB, manifest: manifestA)
        let wrongAttachment = replacingAttachmentId(
            in: valid,
            with: "33333333-3333-4333-8333-333333333333"
        )
        let wrongCid = replacingCid(in: valid, with: "messaging:another-channel")
        let wrongAsset = replacingFirstAssetCipherSize(in: valid, delta: 1)
        let missingManifest = makeManifest(
            attachmentId: "44444444-4444-4444-8444-444444444444",
            originalAssetId: "dddddddd-dddd-4ddd-8ddd-ddddddddddd1",
            previewAssetId: "dddddddd-dddd-4ddd-8ddd-ddddddddddd2",
            fileSuffix: "missing"
        )
        let corruptManifest = makeManifest(
            attachmentId: "55555555-5555-4555-8555-555555555555",
            originalAssetId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1",
            previewAssetId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2",
            fileSuffix: "corrupt"
        )

        let joined = E2eeChannelAttachmentProjectionJoiner.makeItems(
            projections: [
                valid,
                wrongMessage,
                wrongAttachment,
                wrongCid,
                wrongAsset,
                makeProjection(messageId: missingMessage, manifest: missingManifest),
                makeProjection(messageId: corruptMessage, manifest: corruptManifest),
            ],
            expectedCid: cid,
            payloadsByMessageId: payloads,
            cachedPreview: { _ in nil }
        )

        XCTAssertEqual(joined.items.map(\.attachmentId), [manifestA.attachmentId])
        XCTAssertEqual(joined.items.map(\.messageId), [messageA])
        XCTAssertEqual(joined.items.map(\.cid), [cid])
        XCTAssertEqual(joined.unavailableCount, 6)
    }

    func testEffectiveE2eeRoutingIncludesTopicParentAndLeavesStandardChannelDisabled() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        var parentEnabled = false
        var topicEnabled = false
        var standardEnabled = true
        try database.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            let parentCid = try ChannelId(cid: "messaging:test-project:e2ee-parent")
            let topicCid = try ChannelId(cid: "messaging:test-project:e2ee-topic")
            let standardCid = try ChannelId(cid: "messaging:test-project:standard")
            let now = Date().bridgeDate

            let parent = ChannelDTO.loadOrCreate(cid: parentCid, context: context, cache: nil)
            parent.createdAt = now
            parent.updatedAt = now
            parent.defaultSortingAt = now
            parent.mlsEnabled = true

            let topic = ChannelDTO.loadOrCreate(cid: topicCid, context: context, cache: nil)
            topic.createdAt = now
            topic.updatedAt = now
            topic.defaultSortingAt = now
            topic.parentcid = parentCid.rawValue
            topic.parent = parent
            topic.mlsEnabled = false

            let standard = ChannelDTO.loadOrCreate(cid: standardCid, context: context, cache: nil)
            standard.createdAt = now
            standard.updatedAt = now
            standard.defaultSortingAt = now
            standard.mlsEnabled = false

            parentEnabled = parent.isE2eeEnabled
            topicEnabled = topic.isE2eeEnabled
            standardEnabled = standard.isE2eeEnabled
        }

        XCTAssertTrue(parentEnabled)
        XCTAssertTrue(topicEnabled)
        XCTAssertFalse(standardEnabled)
    }

    func testRelaunchRebuildsProjectionFromDurableManifestWithoutPlaintextOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "E2eeChannelAttachmentDurableJoinTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("chat.sqlite")
        let messageId = "relaunch-message-\(UUID().uuidString)"
        let manifest = makeManifest(
            attachmentId: UUID().uuidString,
            originalAssetId: UUID().uuidString,
            previewAssetId: UUID().uuidString,
            fileSuffix: "relaunch"
        )
        let plaintextSentinel = "PLAINTEXT-ORIGINAL-MUST-NOT-BE-PERSISTED"

        let initialDatabase = try makeDatabase(kind: .onDisk(databaseFileURL: databaseURL))
        try initialDatabase.writeAndWait { session in
            try session.saveMessageDecrypt(
                payload: makePayload(manifest),
                messageId: messageId,
                ciphertextHash: Data([4])
            )
        }
        try close(initialDatabase)

        let reopenedDatabase = try makeDatabase(kind: .onDisk(databaseFileURL: databaseURL))
        defer { try? close(reopenedDatabase) }

        let payloads = try await E2eeChannelAttachmentDurableManifestStore.loadPayloads(
            messageIds: [messageId],
            databaseContainer: reopenedDatabase
        )
        let joined = E2eeChannelAttachmentProjectionJoiner.makeItems(
            projections: [makeProjection(messageId: messageId, manifest: manifest)],
            expectedCid: cid,
            payloadsByMessageId: payloads,
            cachedPreview: { _ in nil }
        )

        let item = try XCTUnwrap(joined.items.first)
        XCTAssertEqual(joined.items.count, 1)
        XCTAssertEqual(joined.unavailableCount, 0)
        XCTAssertEqual(item.messageId, messageId)
        XCTAssertEqual(item.attachmentId, manifest.attachmentId)
        XCTAssertNil(item.attachment.thumbnailData)
        XCTAssertEqual(item.attachment.remoteURL?.scheme, "ermis-e2ee-attachment")

        var durableAttachmentData: Data?
        reopenedDatabase.backgroundReadOnlyContext.performAndWait {
            durableAttachmentData = MessageDecryptDTO.load(
                messageId: messageId,
                context: reopenedDatabase.backgroundReadOnlyContext
            )?.attachmentsData
        }
        let durableJSON = String(decoding: try XCTUnwrap(durableAttachmentData), as: UTF8.self)
        XCTAssertFalse(durableJSON.contains(plaintextSentinel))

        let publicPayloadJSON = String(decoding: item.attachment.payload, as: UTF8.self)
        XCTAssertFalse(publicPayloadJSON.contains(plaintextSentinel))
        XCTAssertFalse(publicPayloadJSON.contains(manifest.assets[0].contentKey))
        XCTAssertFalse(publicPayloadJSON.contains(manifest.assets[0].noncePrefix))
    }

    private func makeDatabase() throws -> DatabaseContainer {
        try makeDatabase(kind: .inMemory)
    }

    private func makeDatabase(kind: DatabaseContainer.Kind) throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: kind,
            shouldResetEphemeralValuesOnStart: false
        )
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [storeLoaded], timeout: 5), .completed)
        return database
    }

    private func close(_ database: DatabaseContainer) throws {
        for context in database.allContext {
            context.performAndWait { context.reset() }
        }
        for store in database.persistentStoreCoordinator.persistentStores {
            try database.persistentStoreCoordinator.remove(store)
        }
    }

    private func makePayload(_ manifest: E2eeAttachmentManifestV1) -> E2ePayload {
        E2ePayload(text: "", attachments: [], e2eeAttachments: [manifest], stickerUrl: nil)
    }

    private func makeManifest(
        attachmentId: String,
        originalAssetId: String,
        previewAssetId: String,
        fileSuffix: String
    ) -> E2eeAttachmentManifestV1 {
        let key = Data(repeating: 1, count: E2eeAttachmentFrameCryptoV1.keySize).base64EncodedString()
        let nonce = Data(repeating: 2, count: E2eeAttachmentFrameCryptoV1.noncePrefixSize)
            .base64EncodedString()
        return E2eeAttachmentManifestV1(
            attachmentId: attachmentId,
            assets: [
                E2eeAttachmentManifestAssetV1(
                    assetId: originalAssetId,
                    kind: .original,
                    cipherSize: 1_048,
                    cipherSha256: String(repeating: "a", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: key,
                    noncePrefix: nonce,
                    plaintextSize: 1_024,
                    plaintextSha256: String(repeating: "b", count: 64),
                    display: [
                        "name": .string("photo-\(fileSuffix).jpg"),
                        "mime_type": .string("image/jpeg"),
                        "width": .number(480),
                        "height": .number(320)
                    ]
                ),
                E2eeAttachmentManifestAssetV1(
                    assetId: previewAssetId,
                    kind: .preview,
                    cipherSize: 536,
                    cipherSha256: String(repeating: "c", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: key,
                    noncePrefix: nonce,
                    plaintextSize: 512,
                    plaintextSha256: String(repeating: "d", count: 64),
                    display: ["mime_type": .string("image/jpeg")]
                )
            ]
        )
    }

    private func makeProjection(
        messageId: String,
        manifest: E2eeAttachmentManifestV1
    ) -> QueryE2eeAttachmentProjection {
        QueryE2eeAttachmentProjection(
            attachmentId: manifest.attachmentId,
            messageId: messageId,
            cid: cid.rawValue,
            createdByUserId: "sender",
            createdAt: "2026-08-17T08:00:00Z",
            updatedAt: "2026-08-17T08:00:01Z",
            assets: manifest.assets.map {
                QueryE2eeAttachmentAssetProjection(
                    assetId: $0.assetId,
                    kind: $0.kind.rawValue,
                    cipherSize: $0.cipherSize
                )
            }
        )
    }

    private func replacingAttachmentId(
        in projection: QueryE2eeAttachmentProjection,
        with attachmentId: String
    ) -> QueryE2eeAttachmentProjection {
        replacing(projection, attachmentId: attachmentId)
    }

    private func replacingCid(
        in projection: QueryE2eeAttachmentProjection,
        with cid: String
    ) -> QueryE2eeAttachmentProjection {
        replacing(projection, cid: cid)
    }

    private func replacingFirstAssetCipherSize(
        in projection: QueryE2eeAttachmentProjection,
        delta: UInt64
    ) -> QueryE2eeAttachmentProjection {
        var assets = projection.assets
        let first = assets.removeFirst()
        assets.insert(
            QueryE2eeAttachmentAssetProjection(
                assetId: first.assetId,
                kind: first.kind,
                cipherSize: first.cipherSize + delta
            ),
            at: 0
        )
        return replacing(projection, assets: assets)
    }

    private func replacing(
        _ projection: QueryE2eeAttachmentProjection,
        attachmentId: String? = nil,
        cid: String? = nil,
        assets: [QueryE2eeAttachmentAssetProjection]? = nil
    ) -> QueryE2eeAttachmentProjection {
        QueryE2eeAttachmentProjection(
            attachmentId: attachmentId ?? projection.attachmentId,
            messageId: projection.messageId,
            cid: cid ?? projection.cid,
            createdByUserId: projection.createdByUserId,
            createdAt: projection.createdAt,
            updatedAt: projection.updatedAt,
            assets: assets ?? projection.assets
        )
    }
}
