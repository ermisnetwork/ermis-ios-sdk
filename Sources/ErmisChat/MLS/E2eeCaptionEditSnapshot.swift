import Foundation
import CryptoKit

/// Private local intent. The original message/cipher/cache remain the rollback
/// authority until a matching canonical edit is durably published.
struct E2eeCaptionEditSnapshot: Codable, Equatable {
    let operationId: String
    let messageId: String
    let cid: String
    let baseCiphertextHash: Data
    let payload: E2ePayload
    let metadata: E2eeAuthenticatedMessageMetadata?
    let originalEnvelope: Data
    let aad: Data
    let mentionedUserIds: [String]
    let mentionedAll: Bool

    var authenticatedPayload: E2ePayload { payload.withAuthenticatedMetadata(metadata) }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_194_304 else { throw MlsSendIntentError.capacity }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard UUID(uuidString: value.operationId) != nil, UUID(uuidString: value.messageId) != nil,
              value.baseCiphertextHash.count == 32 else { throw MlsSendIntentError.invalid }
        return value
    }

    static func make(message: MessageDTO, cached: E2ePayload, cid: ChannelId, text: String,
                     mentionedUserIds: [String], mentionedAll: Bool) throws -> Self {
        guard let cipher = message.encryptedData, !cipher.isEmpty,
              message.deletedAt == nil, !message.isHardDeleted else { throw MlsSendIntentError.conflict }
        let payload = E2ePayload(text: text, attachments: cached.attachments,
            e2eeAttachments: cached.e2eeAttachments, stickerUrl: cached.stickerUrl,
            authenticatedMetadata: cached.authenticatedMetadata,
            oldTexts: (cached.oldTexts ?? []) + [.init(text: cached.text, createdAt: message.updatedAt.bridgeDate)])
        var request = message.asRequestBody() as MessageRequestBody
        // Keep immutable routing from the proven canonical cache, replacing only
        // caption and mentions. No URL/key/manifest is derived from composer rows.
        request.text = text; request.encryptedData = nil; request.mlsEpoch = nil; request.groupGeneration = nil
        request.cid = cid
        request.attachments = []
        request.e2eeAttachmentIds = cached.e2eeAttachments.map(\.attachmentId)
        request.e2eeGroupId = message.channel?.mlsGroupCid ?? cid.rawValue
        request.forwardCid = cached.authenticatedMetadata?.forwardCid
        request.forwardParentCid = cached.authenticatedMetadata?.forwardParentCid
        try cached.e2eeAttachments.verifyCanonicalAttachmentIds(request.e2eeAttachmentIds)
        let aad = try request.authenticatedAAD()?.encoded() ?? Data()
        var root = try JSONSerialization.jsonObject(with: JSONEncoder.ermis.encode(["message": request])) as? [String: Any]
        guard var envelope = root?["message"] as? [String: Any] else { throw MlsSendIntentError.invalid }
        envelope["mentioned_users"] = mentionedUserIds; envelope["mentioned_all"] = mentionedAll
        // Caption/history/manifests are encrypted in payload, never server-readable.
        for key in ["text", "attachments", "sticker_url", "old_texts"] { envelope.removeValue(forKey: key) }
        root?["message"] = envelope
        let result = Self(operationId: UUID().uuidString.lowercased(), messageId: message.id.lowercased(), cid: cid.rawValue,
            baseCiphertextHash: Data(SHA256.hash(data: cipher)), payload: payload.withAuthenticatedMetadata(nil), metadata: cached.authenticatedMetadata,
            originalEnvelope: try JSONSerialization.data(withJSONObject: root ?? [:], options: [.sortedKeys]),
            aad: aad, mentionedUserIds: mentionedUserIds, mentionedAll: mentionedAll)
        guard try JSONEncoder().encode(result).count <= 4_194_304 else { throw MlsSendIntentError.capacity }
        return result
    }
}
