//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeAttachmentManifestBuilderError: Error, Equatable {
    case attachmentNotServiceCompleted
    case missingAssetMetadata
    case inconsistentAttachmentSet
}

/// Reconstructs the MLS-only manifest after Bellboy has durably completed every asset. CEK and
/// nonce material is unsealed only for this short-lived value and is never written back into the
/// pending transfer record.
final class E2eeAttachmentManifestBuilder {
    private let wrappingKeyStore: E2eeAttachmentWrappingKeyStore

    init(wrappingKeyStore: E2eeAttachmentWrappingKeyStore) {
        self.wrappingKeyStore = wrappingKeyStore
    }

    func buildCompletedManifests(
        for attempt: PendingE2eeTransferAttempt
    ) throws -> [E2eeAttachmentManifestV1] {
        guard let completionIntents = attempt.completionIntents,
              !completionIntents.isEmpty,
              completionIntents.allSatisfy(\.isServiceCompleted) else {
            throw E2eeAttachmentManifestBuilderError.attachmentNotServiceCompleted
        }
        let completedIds = Set(completionIntents.map(\.attachmentId))
        guard completedIds == Set(attempt.assets.map(\.attachmentId)) else {
            throw E2eeAttachmentManifestBuilderError.inconsistentAttachmentSet
        }
        let attachmentIds = try E2eeMessageAADV1.canonicalAttachmentIds(Array(completedIds))
        return try attachmentIds.map { attachmentId in
            let assets = attempt.assets.filter { $0.attachmentId == attachmentId }
            let assetIds = try E2eeMessageAADV1.canonicalAttachmentIds(assets.map(\.assetId))
            let assetsById = Dictionary(uniqueKeysWithValues: assets.map { ($0.assetId, $0) })
            let manifestAssets = try assetIds.map { assetId -> E2eeAttachmentManifestAssetV1 in
                guard let asset = assetsById[assetId],
                      let cipherSize = asset.ciphertextSize,
                      let cipherSha256 = asset.ciphertextSha256,
                      let sealedSecret = asset.sealedSecret,
                      let frameSize = asset.frameSize,
                      let plaintextSize = asset.plaintextSize,
                      let plaintextSha256 = asset.plaintextSha256 else {
                    throw E2eeAttachmentManifestBuilderError.missingAssetMetadata
                }
                let secret = try wrappingKeyStore.unseal(sealedSecret)
                return E2eeAttachmentManifestAssetV1(
                    assetId: asset.assetId,
                    kind: asset.kind,
                    cipherSize: cipherSize,
                    cipherSha256: cipherSha256,
                    frameSize: frameSize,
                    contentKey: secret.contentKey.base64EncodedString(),
                    noncePrefix: secret.noncePrefix.base64EncodedString(),
                    plaintextSize: plaintextSize,
                    plaintextSha256: plaintextSha256,
                    display: asset.display
                )
            }
            let manifest = E2eeAttachmentManifestV1(
                attachmentId: attachmentId,
                assets: manifestAssets
            )
            try manifest.validate()
            return manifest
        }
    }
}
