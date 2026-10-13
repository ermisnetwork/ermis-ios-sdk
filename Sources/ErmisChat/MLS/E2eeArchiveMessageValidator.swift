import Foundation

/// Common validation gate for live receive and archive replay. All metadata originates in MLS AAD.
enum E2eeArchiveMessageValidator {
    static func validate(_ payload: E2ePayload, processedAAD: Data, messageId: String,
                         cid: String, groupCid: String, expectedEnvelope: E2eeReceivedMessageEnvelope? = nil) throws -> E2ePayload {
        guard !processedAAD.isEmpty else {
            guard payload.e2eeAttachments.isEmpty,
                  expectedEnvelope?.attachmentIds.isEmpty != false else {
                throw E2eeMessageAADError.authenticatedMetadataMismatch
            }
            return payload.withAuthenticatedMetadata(nil)
        }

        let aad = try E2eeMessageAADV1.decoded(from: processedAAD)
        guard aad.isRequired,
              aad.cid == cid,
              aad.e2eeGroupId == groupCid,
              aad.messageId.caseInsensitiveCompare(messageId) == .orderedSame else {
            throw E2eeMessageAADError.authenticatedMetadataMismatch
        }
        try payload.e2eeAttachments.verifyCanonicalAttachmentIds(aad.attachmentIds)
        if let expectedEnvelope {
            let canonicalEnvelopeIds = try E2eeMessageAADV1.canonicalAttachmentIds(
                expectedEnvelope.attachmentIds
            )
            guard expectedEnvelope.forwardCid == aad.forwardCid,
                  expectedEnvelope.forwardMessageId == aad.forwardMessageId,
                  expectedEnvelope.forwardParentCid == aad.forwardParentCid,
                  canonicalEnvelopeIds == aad.attachmentIds else {
                throw E2eeMessageAADError.authenticatedMetadataMismatch
            }
        }
        return payload.withAuthenticatedMetadata(.init(
            forwardCid: aad.forwardCid,
            forwardMessageId: aad.forwardMessageId,
            forwardParentCid: aad.forwardParentCid,
            attachmentIds: aad.attachmentIds
        ))
    }
}
