//
// Copyright 2026 Ermis Inc.
//

import CoreData
import Foundation

/// Serializes durable E2EE inbox and checkpoint writes through the database writer context.
///
/// `fetchCursor` means that the server page is stored locally. It never means that MLS or the
/// message database has applied the page. `applyCursor` advances separately after each event's
/// complete local transaction.
final class E2eeDurableInboxStore {
    static let supersededCommitCategory = "protocol_superseded"

    struct Limits: Equatable {
        let scopeWarningCount: Int
        let scopeMaximumCount: Int
        let accountWarningCount: Int
        let accountMaximumCount: Int
        let pageMaximumRawBytes: Int

        static let `default` = Limits(
            scopeWarningCount: 1_000,
            scopeMaximumCount: 2_000,
            accountWarningCount: 5_000,
            accountMaximumCount: 10_000,
            pageMaximumRawBytes: 16 * 1_024 * 1_024
        )
    }

    struct BacklogSnapshot: Equatable {
        let scopeCid: String
        let scopePendingCount: Int
        let accountPendingCount: Int
        let insertedEventCount: Int
        let pageRawBytes: Int
        let warningThresholdExceeded: Bool
    }

    struct PersistPageResult {
        let insertedEvents: [E2eSyncEventEnvelope]
        let fetchCursor: ScopeSyncCursorPayload?
        let backlog: BacklogSnapshot
    }

    struct CommitPersistenceProof: Equatable {
        let ciphertextHash: Data
        let targetEpoch: UInt64
        let mlsStatePersisted: Bool
    }

    private let database: DatabaseContainer
    private let limits: Limits

    init(database: DatabaseContainer, limits: Limits = .default) {
        self.database = database
        self.limits = limits
    }

    /// Persists a complete server page and its fetch cursor in one Core Data transaction.
    /// A page with `hasMore == true` must provide an authoritative composite cursor.
    func persistPage(
        accountId: String,
        scopeCid: String,
        events: [E2eSyncEventEnvelope],
        hasMore: Bool,
        nextCursor: ScopeSyncCursorPayload?
    ) throws -> PersistPageResult {
        guard !hasMore || nextCursor != nil else {
            throw E2eeDurableInboxError.invalidPagination(scopeCid: scopeCid)
        }

        var pageRawBytes = 0
        for event in events {
            let addition = pageRawBytes.addingReportingOverflow(event.rawEnvelope.count)
            guard !addition.overflow else {
                throw E2eeDurableInboxError.pageTooLarge(
                    scopeCid: scopeCid,
                    rawBytes: .max,
                    maximumRawBytes: limits.pageMaximumRawBytes
                )
            }
            pageRawBytes = addition.partialValue
        }
        guard pageRawBytes <= limits.pageMaximumRawBytes else {
            throw E2eeDurableInboxError.pageTooLarge(
                scopeCid: scopeCid,
                rawBytes: pageRawBytes,
                maximumRawBytes: limits.pageMaximumRawBytes
            )
        }

        var insertedEvents: [E2eSyncEventEnvelope] = []
        var backlog: BacklogSnapshot?
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            for envelope in events {
                let existing = try E2eeInboxEventDTO.load(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    eventId: envelope.eventId,
                    context: context
                )
                if let existing {
                    let canonicalStoredEnvelope = try E2eeWireJSONCanonicalizer.canonicalizeJSONData(
                        existing.rawEnvelope
                    )
                    guard canonicalStoredEnvelope == envelope.rawEnvelope else {
                        throw E2eeDurableInboxError.duplicateEventPayloadMismatch(
                            eventId: envelope.eventId
                        )
                    }
                    if existing.rawEnvelope != canonicalStoredEnvelope {
                        existing.rawEnvelope = canonicalStoredEnvelope
                    }
                } else {
                    insertedEvents.append(envelope)
                }
            }

            let currentScopePending = try E2eeInboxEventDTO.pendingCount(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )
            let currentAccountPending = try E2eeInboxEventDTO.pendingCount(
                accountId: accountId,
                context: context
            )
            let projectedScopePending = currentScopePending + insertedEvents.count
            let projectedAccountPending = currentAccountPending + insertedEvents.count
            guard projectedScopePending <= limits.scopeMaximumCount,
                  projectedAccountPending <= limits.accountMaximumCount else {
                throw E2eeDurableInboxError.backlogLimitExceeded(
                    scopeCid: scopeCid,
                    scopePending: projectedScopePending,
                    accountPending: projectedAccountPending
                )
            }

            backlog = BacklogSnapshot(
                scopeCid: scopeCid,
                scopePendingCount: projectedScopePending,
                accountPendingCount: projectedAccountPending,
                insertedEventCount: insertedEvents.count,
                pageRawBytes: pageRawBytes,
                warningThresholdExceeded: projectedScopePending >= limits.scopeWarningCount
                    || projectedAccountPending >= limits.accountWarningCount
            )

            for envelope in insertedEvents {
                _ = try E2eeInboxEventDTO.insertIfNeeded(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    envelope: envelope,
                    context: context
                )
            }

            if let nextCursor {
                let checkpoint = try E2eeSyncCheckpointDTO.loadOrCreate(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    context: context
                )
                checkpoint.setFetchCursor(nextCursor)
            }
        }

        guard let backlog else {
            throw ClientError.Unexpected("Durable E2EE backlog accounting did not execute.")
        }
        return PersistPageResult(
            insertedEvents: insertedEvents,
            fetchCursor: nextCursor,
            backlog: backlog
        )
    }

    func loadPendingEvents(accountId: String, scopeCid: String) throws -> [E2eSyncEventEnvelope] {
        try readAndWait { context in
            let events = try E2eeInboxEventDTO.loadPending(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ).map { try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope) }
            return events.sorted(by: E2eSyncEventEnvelope.canonicalScopeSyncOrder)
        }
    }

    func fetchCursor(accountId: String, scopeCid: String) throws -> ScopeSyncCursorPayload? {
        try readAndWait { context in
            try E2eeSyncCheckpointDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )?.fetchCursor
        }
    }

    func applyCursor(accountId: String, scopeCid: String) throws -> ScopeSyncCursorPayload? {
        try readAndWait { context in
            try E2eeSyncCheckpointDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )?.applyCursor
        }
    }

    func removedCursor(accountId: String) throws -> RemovedSyncCursorPayload? {
        try readAndWait { context in
            try E2eeSyncCheckpointDTO.load(
                accountId: accountId,
                scopeCid: E2eeSyncCheckpointDTO.removedScope,
                context: context
            )?.removedCursor
        }
    }

    func commitPersistenceProof(
        accountId: String,
        scopeCid: String,
        eventId: String
    ) throws -> CommitPersistenceProof? {
        try readAndWait { context in
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: eventId,
                context: context
            ) else {
                throw E2eeDurableInboxError.eventNotFound(eventId: eventId)
            }
            guard let ciphertextHash = event.protocolCiphertextHash,
                  event.protocolTargetEpoch >= 0 else {
                if event.protocolCiphertextHash != nil || event.protocolTargetEpoch >= 0 {
                    throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: eventId)
                }
                return nil
            }
            return CommitPersistenceProof(
                ciphertextHash: ciphertextHash,
                targetEpoch: UInt64(event.protocolTargetEpoch),
                mlsStatePersisted: event.mlsStatePersisted
            )
        }
    }

    /// Persists the exact commit ciphertext hash and target epoch before OpenMLS processes the
    /// commit. Together with single-writer ordering, this marker proves which durable event may
    /// have advanced the provider if the process dies before the completion marker is written.
    func markCommitProofPersisted(
        accountId: String,
        scopeCid: String,
        eventId: String,
        ciphertextHash: Data,
        targetEpoch: UInt64
    ) throws {
        guard targetEpoch <= UInt64(Int64.max) else {
            throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: eventId)
        }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: eventId,
                context: context
            ) else {
                throw E2eeDurableInboxError.eventNotFound(eventId: eventId)
            }
            let storedEpoch = Int64(targetEpoch)
            if let existingHash = event.protocolCiphertextHash,
               existingHash != ciphertextHash {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: eventId)
            }
            if event.protocolTargetEpoch >= 0,
               event.protocolTargetEpoch != storedEpoch {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: eventId)
            }
            event.protocolCiphertextHash = ciphertextHash
            event.protocolTargetEpoch = storedEpoch
        }
    }

    func markCommitStatePersisted(
        accountId: String,
        scopeCid: String,
        eventId: String,
        ciphertextHash: Data,
        targetEpoch: UInt64
    ) throws {
        guard targetEpoch <= UInt64(Int64.max) else {
            throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: eventId)
        }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: eventId,
                context: context
            ) else {
                throw E2eeDurableInboxError.eventNotFound(eventId: eventId)
            }
            guard event.protocolCiphertextHash == ciphertextHash,
                  event.protocolTargetEpoch == Int64(targetEpoch) else {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: eventId)
            }
            event.mlsStatePersisted = true
        }
    }

    /// Atomically finalizes a historical commit whose target epoch is lower than the provider's
    /// current epoch. The exact event/hash/target remain durable for audit and duplicate checking,
    /// but `mlsStatePersisted` is not promoted: the SDK is explicitly recording that this event
    /// was superseded, not claiming that these exact bytes advanced OpenMLS.
    ///
    /// Applying the event and advancing its exact cursor in the same Core Data transaction makes
    /// relaunch idempotent and releases legacy/migration events that predate commit proof storage.
    func markCommitSuperseded(
        accountId: String,
        scopeCid: String,
        envelope: E2eSyncEventEnvelope,
        ciphertextHash: Data,
        targetEpoch: UInt64
    ) throws {
        guard targetEpoch <= UInt64(Int64.max) else {
            throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
        }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: envelope.eventId,
                context: context
            ) else {
                throw E2eeDurableInboxError.eventNotFound(eventId: envelope.eventId)
            }

            let canonicalStoredEnvelope = try E2eeWireJSONCanonicalizer.canonicalizeJSONData(
                event.rawEnvelope
            )
            guard canonicalStoredEnvelope == envelope.rawEnvelope else {
                throw E2eeDurableInboxError.duplicateEventPayloadMismatch(eventId: envelope.eventId)
            }
            if event.rawEnvelope != canonicalStoredEnvelope {
                event.rawEnvelope = canonicalStoredEnvelope
            }

            let storedEpoch = Int64(targetEpoch)
            if let existingHash = event.protocolCiphertextHash,
               existingHash != ciphertextHash {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
            }
            if event.protocolTargetEpoch >= 0,
               event.protocolTargetEpoch != storedEpoch {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
            }

            // A repeated call for the same finalized row is an idempotent no-op. Do not move the
            // apply cursor backwards if later events have already completed.
            if event.appliedAt == nil {
                let pendingEnvelopes = try E2eeInboxEventDTO.loadFirstPendingTimestampBucket(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    context: context
                ).map { try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope) }
                if let firstPending = pendingEnvelopes.sorted(
                    by: E2eSyncEventEnvelope.canonicalScopeSyncOrder
                ).first,
                   firstPending.eventId != envelope.eventId {
                    throw E2eeDurableInboxError.outOfOrderApply(
                        expectedEventId: firstPending.eventId,
                        actualEventId: envelope.eventId
                    )
                }

                event.protocolCiphertextHash = ciphertextHash
                event.protocolTargetEpoch = storedEpoch
                event.failureCategory = Self.supersededCommitCategory
                event.appliedAt = Date().bridgeDate
                let checkpoint = try E2eeSyncCheckpointDTO.loadOrCreate(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    context: context
                )
                checkpoint.setApplyCursor(
                    ScopeSyncCursorPayload(
                        createdAt: envelope.createdAtRaw,
                        eventId: envelope.eventId
                    )
                )
            } else {
                guard event.failureCategory == Self.supersededCommitCategory,
                      event.protocolCiphertextHash == ciphertextHash,
                      event.protocolTargetEpoch == storedEpoch else {
                    throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
                }
            }

            let repairRequest = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
            repairRequest.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND eventId == %@ AND resolvedAt == nil",
                accountId,
                scopeCid,
                envelope.eventId
            )
            let resolvedAt = Date().bridgeDate
            try context.fetch(repairRequest).forEach { $0.resolvedAt = resolvedAt }
        }
    }

    /// Commits local removal cleanup and the user-scoped removal cursor in one Core Data
    /// transaction. MLS groups are deleted before this method is called because the OpenMLS
    /// provider is a separate database. If this transaction fails, the cursor remains unchanged
    /// and the server page is replayed; group deletion and these Core Data deletes are idempotent.
    func commitRemovedPage(
        accountId: String,
        channelCids: Set<ChannelId>,
        scopeCids: Set<String>,
        nextCursor: RemovedSyncCursorPayload
    ) throws {
        try database.writeAndWait { session in
            guard let context = session as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }

            session.removeChannels(cids: channelCids)

            if !scopeCids.isEmpty {
                let inboxRequest = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
                inboxRequest.predicate = NSPredicate(
                    format: "accountId == %@ AND scopeCid IN %@",
                    accountId,
                    Array(scopeCids)
                )
                try context.fetch(inboxRequest).forEach(context.delete)

                let checkpointRequest = NSFetchRequest<E2eeSyncCheckpointDTO>(entityName: E2eeSyncCheckpointDTO.entityName)
                checkpointRequest.predicate = NSPredicate(
                    format: "accountId == %@ AND scopeCid IN %@",
                    accountId,
                    Array(scopeCids)
                )
                try context.fetch(checkpointRequest).forEach(context.delete)

                let repairRequest = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
                repairRequest.predicate = NSPredicate(
                    format: "accountId == %@ AND scopeCid IN %@",
                    accountId,
                    Array(scopeCids)
                )
                try context.fetch(repairRequest).forEach(context.delete)
            }

            let removedCheckpoint = try E2eeSyncCheckpointDTO.loadOrCreate(
                accountId: accountId,
                scopeCid: E2eeSyncCheckpointDTO.removedScope,
                context: context
            )
            removedCheckpoint.setRemovedCursor(nextCursor)
        }
    }

    /// Records that the plaintext-first application-message transaction and the following MLS
    /// provider save both completed. This marker is diagnostic/recovery proof; cursor movement
    /// still happens only in `markApplied`.
    func markApplicationPersistenceCompleted(
        accountId: String,
        scopeCid: String,
        eventId: String
    ) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: eventId,
                context: context
            ) else {
                throw E2eeDurableInboxError.eventNotFound(eventId: eventId)
            }
            event.plaintextPersisted = true
            event.mlsStatePersisted = true
        }
    }

    /// Marks one event applied and advances only the apply cursor, using the exact raw timestamp
    /// and event ID from the durable envelope.
    func markApplied(
        accountId: String,
        scopeCid: String,
        envelope: E2eSyncEventEnvelope,
        preservingFailure: Bool = false
    ) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            let pendingEnvelopes = try E2eeInboxEventDTO.loadFirstPendingTimestampBucket(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ).map { try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope) }
            if let firstPending = pendingEnvelopes.sorted(
                by: E2eSyncEventEnvelope.canonicalScopeSyncOrder
            ).first,
               firstPending.eventId != envelope.eventId {
                throw E2eeDurableInboxError.outOfOrderApply(
                    expectedEventId: firstPending.eventId,
                    actualEventId: envelope.eventId
                )
            }
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: envelope.eventId,
                context: context
            ) else {
                throw E2eeDurableInboxError.eventNotFound(eventId: envelope.eventId)
            }
            let canonicalStoredEnvelope = try E2eeWireJSONCanonicalizer.canonicalizeJSONData(
                event.rawEnvelope
            )
            guard canonicalStoredEnvelope == envelope.rawEnvelope else {
                throw E2eeDurableInboxError.duplicateEventPayloadMismatch(eventId: envelope.eventId)
            }
            if event.rawEnvelope != canonicalStoredEnvelope {
                event.rawEnvelope = canonicalStoredEnvelope
            }

            event.appliedAt = Date().bridgeDate
            if !preservingFailure {
                event.failureCategory = nil
            }
            let checkpoint = try E2eeSyncCheckpointDTO.loadOrCreate(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )
            checkpoint.setApplyCursor(
                ScopeSyncCursorPayload(
                    createdAt: envelope.createdAtRaw,
                    eventId: envelope.eventId
                )
            )
        }
    }

    func recordRepairIssue(
        accountId: String,
        scopeCid: String,
        eventId: String?,
        category: String,
        details: String?
    ) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            if let eventId,
               let event = try E2eeInboxEventDTO.load(
                   accountId: accountId,
                   scopeCid: scopeCid,
                   eventId: eventId,
                   context: context
               ) {
                event.failureCategory = category
            }
            E2eeRepairIssueDTO.create(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: eventId,
                category: category,
                details: details,
                context: context
            )
        }
    }

    private func readAndWait<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        var result: Result<T, Error>?
        let context = database.writableContext
        context.performAndWait {
            result = Result { try body(context) }
        }
        guard let result else {
            throw ClientError.Unexpected("Durable E2EE database read did not execute.")
        }
        return try result.get()
    }
}
