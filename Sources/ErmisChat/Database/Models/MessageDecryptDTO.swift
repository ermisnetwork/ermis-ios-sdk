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
    /// JSON-encoded `E2eCachedAttachments` envelope after decryption. Older rows can still hold a
    /// direct `[MessageAttachmentPayload]` and are migrated lazily when next written.
    @NSManaged var attachmentsData: Data?
    /// SHA-256 of the exact MLS ciphertext that produced this plaintext cache.
    @NSManaged var ciphertextHash: Data?

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
        messageId: String,
        ciphertextHash: Data?
    ) throws -> MessageDecryptDTO {
        let dto = MessageDecryptDTO.loadOrCreate(messageId: messageId, context: self)
        dto.text = payload.text
        dto.stickerUrl = payload.stickerUrl
        dto.ciphertextHash = ciphertextHash

        if !payload.attachments.isEmpty || !payload.e2eeAttachments.isEmpty {
            dto.attachmentsData = try JSONEncoder.default.encode(
                E2eCachedAttachments(
                    legacy: payload.attachments,
                    e2ee: payload.e2eeAttachments
                )
            )
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
        var cachedAttachments = E2eCachedAttachments()
        if let data = attachmentsData {
            cachedAttachments = try E2eCachedAttachments.decodeCompatible(from: data)
        }
        return E2ePayload(
            text: text,
            attachments: cachedAttachments.legacy,
            e2eeAttachments: cachedAttachments.e2ee,
            stickerUrl: stickerUrl
        )
    }
}

/// Versioned cache envelope for both attachment lanes. Keeping this inside the existing binary
/// Core Data attribute avoids a schema migration while retaining read compatibility with rows
/// written by pre-M2 SDK versions.
struct E2eCachedAttachments: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let legacy: [MessageAttachmentPayload]
    let e2ee: [E2eeAttachmentManifestV1]

    init(
        version: Int = currentVersion,
        legacy: [MessageAttachmentPayload] = [],
        e2ee: [E2eeAttachmentManifestV1] = []
    ) {
        self.version = version
        self.legacy = legacy
        self.e2ee = e2ee
    }

    static func decodeCompatible(from data: Data) throws -> Self {
        let decoder = JSONDecoder.default
        if let envelope = try? decoder.decode(Self.self, from: data) {
            guard envelope.version == currentVersion else {
                throw E2eCachedAttachmentsError.unsupportedVersion(envelope.version)
            }
            guard envelope.legacy.isEmpty || envelope.e2ee.isEmpty else {
                throw E2ePayloadCodingError.mixedAttachmentLanes
            }
            return envelope
        }
        if let legacy = try? decoder.decode([MessageAttachmentPayload].self, from: data) {
            return Self(legacy: legacy)
        }
        // Accept the short-lived direct-manifest representation if an intermediate local build
        // wrote it before the versioned envelope landed.
        if let e2ee = try? decoder.decode([E2eeAttachmentManifestV1].self, from: data) {
            return Self(e2ee: e2ee)
        }
        throw E2eCachedAttachmentsError.invalidPayload
    }
}

enum E2eCachedAttachmentsError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidPayload
}
