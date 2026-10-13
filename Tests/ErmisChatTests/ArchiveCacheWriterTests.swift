import Foundation
import CoreData
import CryptoKit
import XCTest
@testable import ErmisChat

final class ArchiveCacheWriterTests: XCTestCase {
    private let id = "archive-cache-writer"
    private func database() throws -> DatabaseContainer {
        let db = DatabaseContainer(kind: .onDisk(databaseFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("apin-writer-\(UUID().uuidString).sqlite")), shouldResetEphemeralValuesOnStart: false)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !db.persistentStoreCoordinator.persistentStores.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        return db
    }
    private func row(_ session: DatabaseSession, ciphertext: Data?) -> MessageDTO {
        let row = MessageDTO.loadOrCreate(id: id, context: session as! NSManagedObjectContext, cache: nil)
        row.cid = "messaging:archive-fixture"; row.encryptedData = ciphertext; row.type = "regular"
        row.createdAt = DBDate(); row.updatedAt = DBDate(); row.text = "fixture"
        row.isSilent = false; row.mentionedAll = false; row.reactionCounts = [:]; row.reactionScores = [:]
        return row
    }
    private var proven: E2ePayload { E2ePayload(text: "current-fixture", attachments: [], stickerUrl: nil,
        authenticatedMetadata: .init(forwardCid: "messaging:source", forwardMessageId: "source-id", forwardParentCid: nil, attachmentIds: [])) }
    private func close(_ db: DatabaseContainer) throws {
        for context in db.allContext { context.performAndWait { context.reset() } }
        for store in db.persistentStoreCoordinator.persistentStores { try db.persistentStoreCoordinator.remove(store) }
    }
    func testWeakWriterCannotDowngradeCurrentBoundCache() throws {
        let db = try database()
        defer { try? close(db) }
        try db.writeAndWait { session in
            let cipher = Data([2]); _ = self.row(session, ciphertext: cipher)
            try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: Data(SHA256.hash(data: cipher)))
            let saved = try session.saveMessageDecrypt(payload: E2ePayload(text: "weak-fixture", attachments: [], stickerUrl: nil), messageId: self.id, ciphertextHash: nil)
            XCTAssertEqual(try saved.asPayload(), self.proven)
            XCTAssertEqual(saved.ciphertextHash, Data(SHA256.hash(data: cipher)))
        }
    }
    func testStaleBoundWriterAndStaleReadCannotExposeMetadata() throws {
        let db = try database()
        defer { try? close(db) }
        try db.writeAndWait { session in
            let cipher = Data([2]); let message = self.row(session, ciphertext: cipher)
            let dto = try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: Data(SHA256.hash(data: cipher)))
            XCTAssertThrowsError(try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: Data(SHA256.hash(data: Data([1])))))
            XCTAssertEqual(dto.ciphertextHash, Data(SHA256.hash(data: cipher)))
            message.encryptedData = Data([3])
            XCTAssertThrowsError(try dto.asPayload())
            XCTAssertEqual(dto.ciphertextHash, Data(SHA256.hash(data: cipher)), "Stale rows are retained for scoped repair")
        }
    }
    func testLocalUnboundDraftRemainsWritableAndDeletedBoundWriteIsRejected() throws {
        let db = try database()
        defer { try? close(db) }
        try db.writeAndWait { session in
            let message = self.row(session, ciphertext: nil)
            let draft = try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: nil)
            XCTAssertEqual(try draft.asPayload(), self.proven)
            message.encryptedData = Data([2]); message.deletedAt = DBDate()
            XCTAssertThrowsError(try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: Data(SHA256.hash(data: Data([2])))))
        }
    }
    func testUnboundReceivedCacheQuarantinesMetadataWhilePendingIntentRemainsReadable() throws {
        let db = try database()
        defer { try? close(db) }
        try db.writeAndWait { session in
            let message = self.row(session, ciphertext: Data([2]))
            let dto = try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: nil)
            XCTAssertNil(try dto.asPayload().authenticatedMetadata)
            XCTAssertTrue(try dto.asPayload().attachments.isEmpty)
            message.localMessageState = .pendingSend
            XCTAssertEqual(try dto.asPayload(), self.proven)
            try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: Data(SHA256.hash(data: Data([2]))))
            message.localMessageState = nil
            XCTAssertEqual(try dto.asPayload(), self.proven)
        }
    }
    func testReceivedEncryptedRowCannotRenderOldAttachmentDtoFallback() throws {
        let db = try database()
        defer { try? close(db) }
        try db.writeAndWait { session in
            let context = session as! NSManagedObjectContext
            let message = self.row(session, ciphertext: Data([2]))
            let user = UserDTO.loadOrCreate(id: "fixture", projectId: "project", context: context, cache: nil)
            user.projectId = "project"; message.user = user
            let cid = try ChannelId(cid: "messaging:project:archive-fixture")
            let attachment = try session.saveAttachment(payload: MessageAttachmentPayload(type: .file,
                payload: ["asset_url": .string("https://fixture.invalid/unproven"), "title": .string("fixture")]),
                id: AttachmentId(cid: cid, messageId: self.id, index: 0))
            message.attachments = [attachment]
            try session.saveMessageDecrypt(payload: self.proven, messageId: self.id, ciphertextHash: nil)
            let model = try message.asModel()
            XCTAssertTrue(model.allAttachments.isEmpty)
            XCTAssertNil(model.forwardChannelId)
            XCTAssertNotNil(message.encryptedData)
            XCTAssertEqual(message.attachments.count, 1, "Quarantine retains the old scoped row")
        }
    }
}
