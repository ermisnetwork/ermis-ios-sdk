//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

/// A CoreData entity that caches the decrypted content of an encrypted message.
/// Linked one-to-one with `MessageDTO` via the `decryptedMessage` relationship.
@objc(MessageDecryptDTO)
class MessageDecryptDTO: NSManagedObject {
    /// The message ID this decrypted cache belongs to (mirrors `MessageDTO.id`).
    @NSManaged var messageId: String
    /// The decrypted plain-text content of the message.
    @NSManaged var text: String
    /// The decrypted sticker URL, if any.
    @NSManaged var stickerUrl: URL?
    /// JSON-encoded array of `MessageAttachmentPayload` after decryption.
    @NSManaged var attachmentsData: Data?

    // MARK: - Relationship

    /// The parent message this decrypted cache belongs to.
    @NSManaged var message: MessageDTO?
}

// MARK: - Loading

extension MessageDecryptDTO {
    /// Fetches an existing `MessageDecryptDTO` for the given message ID, or returns `nil`.
    static func load(messageId: String, context: NSManagedObjectContext) -> MessageDecryptDTO? {
        let request = NSFetchRequest<MessageDecryptDTO>(entityName: MessageDecryptDTO.entityName)
        request.predicate = NSPredicate(format: "messageId == %@", messageId)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// Fetches an existing `MessageDecryptDTO` for the given message ID, or creates a new one.
    static func loadOrCreate(messageId: String, context: NSManagedObjectContext) -> MessageDecryptDTO {
        if let existing = load(messageId: messageId, context: context) {
            return existing
        }
        let new = NSEntityDescription.insertNewObject(
            forEntityName: MessageDecryptDTO.entityName,
            into: context
        ) as! MessageDecryptDTO
        new.messageId = messageId
        return new
    }
}

// MARK: - Saving from E2ePayload

extension NSManagedObjectContext: E2eDatabaseSession {
    /// Creates or updates a `MessageDecryptDTO` from a decrypted `E2ePayload`.
    ///
    /// - Parameters:
    ///   - payload: The decrypted E2E payload.
    ///   - messageId: The ID of the parent message.
    /// - Returns: The saved `MessageDecryptDTO`.
    @discardableResult
    func saveMessageDecrypt(
        payload: E2ePayload,
        messageId: String
    ) throws -> MessageDecryptDTO {
        let dto = MessageDecryptDTO.loadOrCreate(messageId: messageId, context: self)
        dto.text = payload.text
        dto.stickerUrl = payload.stickerUrl

        if !payload.attachments.isEmpty {
            dto.attachmentsData = try JSONEncoder.default.encode(payload.attachments)
        } else {
            dto.attachmentsData = nil
        }

        // Link to the parent MessageDTO so CoreData propagates the change
        // and NSFetchedResultsController triggers a UI reload.
        if dto.message == nil {
            dto.message = message(id: messageId)
        }

        return dto
    }

    // MARK: - Pending Remove Member

    @discardableResult
    func savePendingRemoveMember(userId: String, channelCid: String) -> PendingRemoveMemberDTO {
        PendingRemoveMemberDTO.createOrLoad(userId: userId, channelCid: channelCid, context: self)
    }

    func loadPendingRemoveMemberUserIds(channelCid: String) -> [String] {
        PendingRemoveMemberDTO.loadAll(channelCid: channelCid, context: self).map(\.userId)
    }

    func deletePendingRemoveMember(userId: String, channelCid: String) {
        guard let dto = PendingRemoveMemberDTO.load(userId: userId, channelCid: channelCid, context: self) else { return }
        delete(dto)
    }

    func deletePendingRemoveMembers(userIds: [String], channelCid: String) {
        for userId in userIds {
            deletePendingRemoveMember(userId: userId, channelCid: channelCid)
        }
    }
}

// MARK: - Model conversion

extension MessageDecryptDTO {
    /// Reconstructs the `E2ePayload` from the cached decrypted data.
    func asPayload() throws -> E2ePayload {
        var attachments: [MessageAttachmentPayload] = []
        if let data = attachmentsData {
            attachments = try JSONDecoder.default.decode([MessageAttachmentPayload].self, from: data)
        }
        return E2ePayload(text: text, attachments: attachments, stickerUrl: stickerUrl)
    }
}
