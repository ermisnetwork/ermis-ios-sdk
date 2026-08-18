//
// Copyright 2026 Ermis Inc.
//

import Foundation

protocol E2eeAttachmentCompletionClient: AnyObject {
    func completePendingE2eeAttachment(
        cid: ChannelId,
        attachmentId: String,
        request: CompleteE2eeAttachmentRequest
    ) async throws
}

/// Deletes a completed-but-unbound attachment after the local wrapping key has been proven lost.
/// This is intentionally separate from completion: deletion is best effort and must never make a
/// terminal local-key-loss record retryable.
protocol E2eeAttachmentUnboundDeletionClient: AnyObject {
    func deleteUnboundE2eeAttachment(
        cid: ChannelId,
        attachmentId: String
    ) async throws
}

protocol E2eeAttachmentMessageBinding: AnyObject {
    func persistCompletedE2eeAttachmentManifests(
        messageId: String,
        manifests: [E2eeAttachmentManifestV1]
    ) async throws

    /// Returns only after Bellboy's authoritative response has been persisted locally.
    func sendPreparedE2eeAttachmentMessage(messageId: String) async throws
}

extension APIClient: E2eeAttachmentCompletionClient {
    func completePendingE2eeAttachment(
        cid: ChannelId,
        attachmentId: String,
        request: CompleteE2eeAttachmentRequest
    ) async throws {
        _ = try await completeE2eeAttachment(
            cid: cid,
            attachmentId: attachmentId,
            request: request
        )
    }
}

extension APIClient: E2eeAttachmentUnboundDeletionClient {
    func deleteUnboundE2eeAttachment(
        cid: ChannelId,
        attachmentId: String
    ) async throws {
        _ = try await deleteE2eeAttachment(cid: cid, attachmentId: attachmentId)
    }
}

enum E2eeAttachmentFinalizerError: Error, Equatable {
    case invalidChannelId
    case attemptNotReady
    case transportIncomplete
    case inconsistentAttachment
}

/// Completes uploaded Bellboy attachments using a durable client-generated lease. An unknown
/// result never creates a new lease or ETag list: retry replays the exact persisted intent.
final class E2eeAttachmentFinalizer {
    private let store: E2eeDurableTransferStore
    private let stagingStore: E2eeAttachmentStagingStore
    private let client: E2eeAttachmentCompletionClient
    private let deletionClient: E2eeAttachmentUnboundDeletionClient?
    private let manifestBuilder: E2eeAttachmentManifestBuilder?
    private weak var messageBinding: E2eeAttachmentMessageBinding?
    private let cancelScheduledTasks: ((PendingE2eeTransferAttempt) async -> Void)?
    private let stateDidChange: () -> Void
    private let inFlightLock = NSLock()
    private var inFlightAttemptIds = Set<String>()

    init(
        store: E2eeDurableTransferStore,
        stagingStore: E2eeAttachmentStagingStore,
        client: E2eeAttachmentCompletionClient,
        deletionClient: E2eeAttachmentUnboundDeletionClient? = nil,
        manifestBuilder: E2eeAttachmentManifestBuilder? = nil,
        messageBinding: E2eeAttachmentMessageBinding? = nil,
        cancelScheduledTasks: ((PendingE2eeTransferAttempt) async -> Void)? = nil,
        stateDidChange: @escaping () -> Void = {}
    ) {
        self.store = store
        self.stagingStore = stagingStore
        self.client = client
        self.deletionClient = deletionClient
        self.manifestBuilder = manifestBuilder
        self.messageBinding = messageBinding
        self.cancelScheduledTasks = cancelScheduledTasks
        self.stateDidChange = stateDidChange
    }

    func finalizeReadyAttempts() async {
        guard let attempts = try? store.hydrate() else { return }
        for attempt in attempts {
            if attempt.phase == .failedTerminal,
               attempt.failureReason == .localKeyUnavailableAfterReinstall,
               Self.hasWrappingKeyLossArtifacts(attempt),
               let cid = try? ChannelId(cid: attempt.cid) {
                await finishWrappingKeyLossCleanup(attempt: attempt, cid: cid)
                continue
            }
            guard attempt.phase == .finalizing
                || attempt.phase == .waitingForUnlock
                || attempt.phase == .sending else { continue }
            do {
                _ = try await finalize(attemptId: attempt.attemptId)
            } catch {
                log.error(
                    "[E2EE_ATTACHMENT] stage=finalize result=failed error=\(type(of: error))",
                    subsystems: .mls
                )
            }
            stateDidChange()
        }
    }

    @discardableResult
    func finalize(attemptId: String) async throws -> PendingE2eeTransferAttempt {
        guard begin(attemptId: attemptId) else {
            return try store.attempt(attemptId: attemptId)
        }
        defer { end(attemptId: attemptId) }

        var attempt = try store.attempt(attemptId: attemptId)
        if attempt.phase == .failedRetryable,
           attempt.completionIntents != nil,
           [.networkUnavailable, .serviceTemporarilyUnavailable, .unknown].contains(attempt.failureReason) {
            attempt = try store.update(attemptId: attemptId) { record in
                record.phase = .finalizing
                record.failureReason = nil
            }
            stateDidChange()
        }
        if attempt.phase == .waitingForUnlock,
           attempt.completionIntents?.allSatisfy(\.isServiceCompleted) == true {
            attempt = try store.update(attemptId: attemptId) { record in
                record.phase = .finalizing
                record.failureReason = nil
            }
            stateDidChange()
        }
        if attempt.phase == .sending {
            guard messageBinding != nil else { return attempt }
            return try await completeMessageBinding(attempt)
        }
        guard attempt.phase == .finalizing else {
            throw E2eeAttachmentFinalizerError.attemptNotReady
        }

        let cid: ChannelId
        do {
            cid = try ChannelId(cid: attempt.cid)
        } catch {
            try markFailure(attemptId: attemptId, reason: .invalidServerResponse, retryable: false)
            throw E2eeAttachmentFinalizerError.invalidChannelId
        }

        if attempt.completionIntents == nil {
            do {
                let intents = try Self.makeCompletionIntents(for: attempt)
                attempt = try store.update(attemptId: attemptId) { record in
                    guard record.completionIntents == nil else { return }
                    record.completionIntents = intents
                }
                stateDidChange()
            } catch {
                try markFailure(attemptId: attemptId, reason: .invalidServerResponse, retryable: false)
                throw error
            }
        }

        for intent in attempt.completionIntents ?? [] where !intent.isServiceCompleted {
            log.info(
                "[E2EE_ATTACHMENT] stage=complete state=requesting",
                subsystems: .mls
            )
            do {
                try await client.completePendingE2eeAttachment(
                    cid: cid,
                    attachmentId: intent.attachmentId,
                    request: intent.request
                )
            } catch {
                let classification = Self.classify(error)
                try markFailure(
                    attemptId: attemptId,
                    reason: classification.reason,
                    retryable: classification.retryable
                )
                throw error
            }
            log.info(
                "[E2EE_ATTACHMENT] stage=complete state=succeeded",
                subsystems: .mls
            )

            // Persist authoritative service completion before removing any SDK staging.
            attempt = try store.update(attemptId: attemptId) { record in
                guard let index = record.completionIntents?.firstIndex(where: {
                    $0.attachmentId == intent.attachmentId
                }) else {
                    throw E2eeAttachmentFinalizerError.inconsistentAttachment
                }
                record.completionIntents?[index].isServiceCompleted = true
            }
            stateDidChange()
            try cleanupCompletedMultipartStaging(
                attemptId: attemptId,
                attachmentId: intent.attachmentId,
                assets: attempt.assets
            )
        }
        attempt = try store.attempt(attemptId: attemptId)
        guard let manifestBuilder, let messageBinding else { return attempt }
        log.info(
            "[E2EE_ATTACHMENT] stage=complete state=all_succeeded",
            subsystems: .mls
        )

        let manifests: [E2eeAttachmentManifestV1]
        do {
            manifests = try manifestBuilder.buildCompletedManifests(for: attempt)
        } catch let error as E2eeAttachmentWrappingKeyError {
            switch error {
            case .waitingForFirstUnlock, .temporarilyUnavailable, .wrappingKeyNotInitialized:
                _ = try store.update(attemptId: attemptId) { record in
                    record.phase = .waitingForUnlock
                    record.failureReason = nil
                }
                stateDidChange()
            case .localKeyUnavailableAfterReinstall:
                await handleWrappingKeyLoss(attempt: attempt, cid: cid)
            default:
                try markFailure(attemptId: attemptId, reason: .integrityFailure, retryable: false)
            }
            throw error
        } catch {
            try markFailure(attemptId: attemptId, reason: .integrityFailure, retryable: false)
            throw error
        }

        do {
            // The message cache becomes durable before `.sending`. A crash before the next state
            // write simply rebuilds the same manifest from sealed material and repeats this write.
            log.info(
                "[E2EE_ATTACHMENT] stage=message_binding state=persisting_manifest",
                subsystems: .mls
            )
            try await messageBinding.persistCompletedE2eeAttachmentManifests(
                messageId: attempt.messageId,
                manifests: manifests
            )
        } catch {
            try markFailure(attemptId: attempt.attemptId, reason: .unknown, retryable: true)
            throw error
        }
        log.info(
            "[E2EE_ATTACHMENT] stage=message_binding state=manifest_persisted",
            subsystems: .mls
        )
        attempt = try store.update(attemptId: attemptId) { record in
            record.phase = .sending
            record.failureReason = nil
        }
        stateDidChange()
        return try await completeMessageBinding(attempt)
    }

    private func completeMessageBinding(
        _ attempt: PendingE2eeTransferAttempt
    ) async throws -> PendingE2eeTransferAttempt {
        guard let messageBinding else {
            throw E2eeAttachmentFinalizerError.attemptNotReady
        }
        log.info("[E2EE_ATTACHMENT] stage=message_binding state=send_started", subsystems: .mls)
        do {
            try await messageBinding.sendPreparedE2eeAttachmentMessage(
                messageId: attempt.messageId
            )
        } catch {
            // The exact MLS/message intent and completed attachment IDs remain durable. A retry
            // reuses them instead of creating another attachment or ciphertext generation.
            try markFailure(attemptId: attempt.attemptId, reason: .unknown, retryable: true)
            log.error(
                "[E2EE_ATTACHMENT] stage=message_binding state=send_failed error=\(type(of: error))",
                subsystems: .mls
            )
            throw error
        }

        // Message success means the authoritative response is already in Core Data. Persist the
        // transfer terminal state at this boundary rather than relying on an unrelated callback.
        var confirmedAttempt = try store.update(attemptId: attempt.attemptId) { record in
            record.phase = .confirmed
            record.failureReason = nil
        }
        stateDidChange()
        try cleanupConfirmedStaging(attemptId: attempt.attemptId)
        log.info(
            "[E2EE_ATTACHMENT] stage=message_binding state=confirmed",
            subsystems: .mls
        )
        confirmedAttempt = try store.attempt(attemptId: attempt.attemptId)
        return confirmedAttempt
    }

    private func cleanupCompletedMultipartStaging(
        attemptId: String,
        attachmentId: String,
        assets: [PendingE2eeAsset]
    ) throws {
        for asset in assets where asset.attachmentId == attachmentId && asset.uploadMode == .multipart {
            try stagingStore.removeMultipartAssetDirectory(
                attemptId: attemptId,
                assetId: asset.assetId
            )
        }
    }

    private func cleanupConfirmedStaging(attemptId: String) throws {
        let attempt = try store.attempt(attemptId: attemptId)
        guard attempt.phase == .confirmed else { return }
        for asset in attempt.assets {
            if let sourceURL = asset.sourceURL {
                try stagingStore.removeSource(sourceURL)
            }
            if let canonicalURL = asset.canonicalCiphertextURL {
                try stagingStore.removeCanonicalCiphertext(canonicalURL)
            }
            try stagingStore.removeMultipartAssetDirectory(
                attemptId: attempt.attemptId,
                assetId: asset.assetId
            )
        }
        _ = try store.update(attemptId: attemptId) { record in
            for assetIndex in record.assets.indices {
                record.assets[assetIndex].sourceURL = nil
                record.assets[assetIndex].canonicalCiphertextURL = nil
                record.assets[assetIndex].taskIdentifier = nil
                record.assets[assetIndex].taskToken = nil
                for partIndex in record.assets[assetIndex].parts.indices {
                    record.assets[assetIndex].parts[partIndex].localFileURL = nil
                    record.assets[assetIndex].parts[partIndex].taskIdentifier = nil
                    record.assets[assetIndex].parts[partIndex].taskToken = nil
                }
            }
        }
        stateDidChange()
    }

    /// The keychain marker proves the app was previously initialized, but its installation-bound
    /// key is now unavailable. The ciphertext cannot be reused safely, so cancel any late OS
    /// work before clearing task mappings, remove local staging, and best-effort delete the
    /// completed attachment which has not yet been bound into a message.
    private func handleWrappingKeyLoss(
        attempt: PendingE2eeTransferAttempt,
        cid: ChannelId
    ) async {
        await cancelScheduledTasks?(attempt)

        let terminalAttempt: PendingE2eeTransferAttempt
        do {
            terminalAttempt = try store.update(attemptId: attempt.attemptId) { record in
                record.phase = .failedTerminal
                record.failureReason = .localKeyUnavailableAfterReinstall
                for assetIndex in record.assets.indices {
                    record.assets[assetIndex].taskIdentifier = nil
                    record.assets[assetIndex].taskToken = nil
                    for partIndex in record.assets[assetIndex].parts.indices {
                        record.assets[assetIndex].parts[partIndex].taskIdentifier = nil
                        record.assets[assetIndex].parts[partIndex].taskToken = nil
                    }
                }
            }
            stateDidChange()
        } catch {
            log.error(
                "[E2EE_ATTACHMENT] stage=wrapping_key_loss state=durable_failure_failed error=\(type(of: error))",
                subsystems: .mls
            )
            return
        }

        await finishWrappingKeyLossCleanup(attempt: terminalAttempt, cid: cid)
    }

    /// Runs after the terminal record is durable. Retaining file URLs until every remove succeeds
    /// gives launch reconciliation enough information to retry cleanup after a process crash.
    private func finishWrappingKeyLossCleanup(
        attempt: PendingE2eeTransferAttempt,
        cid: ChannelId
    ) async {
        var didCleanAllArtifacts = true
        for asset in attempt.assets {
            if let sourceURL = asset.sourceURL {
                didCleanAllArtifacts = removeWrappingKeyLossArtifact {
                    try stagingStore.removeSource(sourceURL)
                } && didCleanAllArtifacts
            }
            if let canonicalURL = asset.canonicalCiphertextURL {
                didCleanAllArtifacts = removeWrappingKeyLossArtifact {
                    try stagingStore.removeCanonicalCiphertext(canonicalURL)
                } && didCleanAllArtifacts
            }
            didCleanAllArtifacts = removeWrappingKeyLossArtifact {
                try stagingStore.removeMultipartAssetDirectory(
                    attemptId: attempt.attemptId,
                    assetId: asset.assetId
                )
            } && didCleanAllArtifacts
        }

        if didCleanAllArtifacts {
            do {
                _ = try store.update(attemptId: attempt.attemptId) { record in
                    for assetIndex in record.assets.indices {
                        record.assets[assetIndex].sourceURL = nil
                        record.assets[assetIndex].canonicalCiphertextURL = nil
                        for partIndex in record.assets[assetIndex].parts.indices {
                            record.assets[assetIndex].parts[partIndex].localFileURL = nil
                        }
                    }
                }
                stateDidChange()
            } catch {
                // The terminal record still retains the paths, so launch reconciliation retries
                // this idempotent cleanup and durable acknowledgement.
                log.error(
                    "[E2EE_ATTACHMENT] stage=wrapping_key_loss state=cleanup_ack_failed error=\(type(of: error))",
                    subsystems: .mls
                )
            }
        }

        // Never delete the service object while the durable record can still look live.
        guard let deletionClient else { return }
        for attachmentId in Set(attempt.assets.map(\.attachmentId)) {
            do {
                try await deletionClient.deleteUnboundE2eeAttachment(
                    cid: cid,
                    attachmentId: attachmentId
                )
            } catch {
                // Server cleanup is deliberately best effort: local state must remain terminal if
                // the request is offline or the attachment has already expired.
                log.error(
                    "[E2EE_ATTACHMENT] stage=wrapping_key_loss state=remote_cleanup_failed error=\(type(of: error))",
                    subsystems: .mls
                )
            }
        }
    }

    private func removeWrappingKeyLossArtifact(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            // Continue through every owned artifact. One failed remove must not leave the other
            // sources, ciphertexts, or multipart directories behind.
            log.error(
                "[E2EE_ATTACHMENT] stage=wrapping_key_loss state=staging_cleanup_failed error=\(type(of: error))",
                subsystems: .mls
            )
            return false
        }
    }

    private static func hasWrappingKeyLossArtifacts(_ attempt: PendingE2eeTransferAttempt) -> Bool {
        attempt.assets.contains { asset in
            asset.sourceURL != nil
                || asset.canonicalCiphertextURL != nil
                || asset.parts.contains { $0.localFileURL != nil }
        }
    }

    private func markFailure(
        attemptId: String,
        reason: E2eeTransferFailureReason,
        retryable: Bool
    ) throws {
        _ = try store.update(attemptId: attemptId) { record in
            record.phase = retryable ? .failedRetryable : .failedTerminal
            record.failureReason = reason
        }
        stateDidChange()
    }

    private func begin(attemptId: String) -> Bool {
        inFlightLock.withLock { inFlightAttemptIds.insert(attemptId).inserted }
    }

    private func end(attemptId: String) {
        _ = inFlightLock.withLock { inFlightAttemptIds.remove(attemptId) }
    }

    private static func makeCompletionIntents(
        for attempt: PendingE2eeTransferAttempt
    ) throws -> [PendingE2eeAttachmentCompletionIntent] {
        guard !attempt.assets.isEmpty else {
            throw E2eeAttachmentFinalizerError.transportIncomplete
        }
        for asset in attempt.assets {
            switch asset.uploadMode {
            case .singlePut:
                guard asset.isUploaded else {
                    throw E2eeAttachmentFinalizerError.transportIncomplete
                }
            case .multipart:
                guard !asset.parts.isEmpty,
                      asset.parts.allSatisfy({ $0.eTag?.isEmpty == false }),
                      asset.parts.allSatisfy({ $0.taskToken == nil && $0.taskIdentifier == nil }) else {
                    throw E2eeAttachmentFinalizerError.transportIncomplete
                }
            case nil:
                throw E2eeAttachmentFinalizerError.transportIncomplete
            }
        }

        // Original and preview legitimately share an attachment ID. Remove that expected
        // duplication before applying the canonical raw-UUID ordering helper.
        let attachmentIdSet = Set(attempt.assets.map(\.attachmentId))
        let canonicalAttachmentIds = try E2eeMessageAADV1.canonicalAttachmentIds(
            Array(attachmentIdSet)
        )
        return try canonicalAttachmentIds.map { attachmentId in
            let attachmentAssets = attempt.assets.filter { $0.attachmentId == attachmentId }
            guard attachmentAssets.contains(where: { $0.kind == .original }) else {
                throw E2eeAttachmentFinalizerError.inconsistentAttachment
            }
            let canonicalAssetIds = try E2eeMessageAADV1.canonicalAttachmentIds(
                attachmentAssets.map(\.assetId)
            )
            let assetsById = Dictionary(uniqueKeysWithValues: attachmentAssets.map { ($0.assetId, $0) })
            let multipartAssets = try canonicalAssetIds.compactMap { assetId -> CompleteE2eeAttachmentAsset? in
                    guard let asset = assetsById[assetId], asset.uploadMode == .multipart else {
                        return nil
                    }
                    let parts = try asset.parts.map { part -> CompleteE2eeAttachmentPart in
                        guard let eTag = part.eTag, !eTag.isEmpty else {
                            throw E2eeAttachmentFinalizerError.transportIncomplete
                        }
                        return .init(partNumber: part.number, eTag: eTag)
                    }
                    return .init(
                        assetId: asset.assetId,
                        multipart: .init(parts: parts)
                    )
                }
            let request = CompleteE2eeAttachmentRequest(
                completionLeaseId: UUID().uuidString,
                assets: multipartAssets.isEmpty ? nil : multipartAssets
            )
            try request.validate()
            return PendingE2eeAttachmentCompletionIntent(
                attachmentId: attachmentId,
                request: request,
                isServiceCompleted: false
            )
        }
    }

    private static func classify(
        _ error: Error
    ) -> (reason: E2eeTransferFailureReason, retryable: Bool) {
        if let remote = error as? E2eeAttachmentRemoteError {
            return (remote.publicFailureReason, remote.isRetryable)
        }
        return (.invalidServerResponse, false)
    }
}
