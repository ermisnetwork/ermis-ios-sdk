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

    struct LocalJoinReceiptProof: Equatable {
        let commitHash: Data
        let epoch: UInt64
        let requestDeviceId: String
        let status: E2eeLocalJoinReceiptStatus
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

    /// Returns only the canonical pending prefix. A page may contain several event kinds with
    /// the same timestamp, so the earliest timestamp bucket is always decoded in full before
    /// the Bellboy kind-rank ordering is applied. This keeps a bounded scheduler from ever
    /// letting an application event overtake a same-timestamp protocol event.
    func loadPendingPrefix(
        accountId: String,
        scopeCid: String,
        limit: Int = 100
    ) throws -> [E2eSyncEventEnvelope] {
        precondition(limit > 0)
        return try readAndWait { context in
            func boundedCanonicalPrefix(
                _ rows: [E2eeInboxEventDTO],
                capacity: Int
            ) throws -> [E2eSyncEventEnvelope] {
                guard capacity > 0 else { return [] }
                var prefix: [E2eSyncEventEnvelope] = []
                prefix.reserveCapacity(capacity)
                for row in rows {
                    let envelope = try JSONDecoder.default.decode(
                        E2eSyncEventEnvelope.self,
                        from: row.rawEnvelope
                    )
                    prefix.append(envelope)
                    prefix.sort(by: E2eSyncEventEnvelope.canonicalScopeSyncOrder)
                    if prefix.count > capacity {
                        prefix.removeLast()
                    }
                }
                return prefix
            }

            let earliestRows = try E2eeInboxEventDTO.loadFirstPendingTimestampBucket(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )
            let earliestBucket = try boundedCanonicalPrefix(earliestRows, capacity: limit)
            guard earliestRows.count < limit else { return earliestBucket }

            // Once the entire earliest bucket is included, a simple Core Data ordered suffix is
            // safe until its final timestamp. Fetch that timestamp bucket in full as well.
            guard let firstDate = earliestBucket.first?.createdAt.bridgeDate else { return [] }
            let suffixRequest = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
            suffixRequest.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND appliedAt == nil AND createdAt > %@",
                accountId,
                scopeCid,
                firstDate
            )
            suffixRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \E2eeInboxEventDTO.createdAt, ascending: true),
                NSSortDescriptor(keyPath: \E2eeInboxEventDTO.eventId, ascending: true)
            ]
            suffixRequest.fetchLimit = limit - earliestBucket.count
            let suffix = try context.fetch(suffixRequest).map {
                try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope)
            }
            guard let terminalDate = suffix.last?.createdAt else {
                return earliestBucket
            }
            // `fetchLimit` can stop part-way through a same-timestamp bucket. Re-fetch that
            // complete terminal bucket before applying kind rank, otherwise a lexical UUID order
            // could still put application before protocol.
            let terminalRequest = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
            terminalRequest.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND appliedAt == nil AND createdAt == %@",
                accountId,
                scopeCid,
                terminalDate.bridgeDate
            )
            let terminalRows = try context.fetch(terminalRequest)
            let beforeTerminal = suffix.filter { $0.createdAt < terminalDate }
            let remainingCapacity = limit - earliestBucket.count - beforeTerminal.count
            let terminalBucket = try boundedCanonicalPrefix(
                terminalRows,
                capacity: remainingCapacity
            )
            return Array((earliestBucket + beforeTerminal + terminalBucket)
                .sorted(by: E2eSyncEventEnvelope.canonicalScopeSyncOrder)
                .prefix(limit))
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

    func prepareLocalJoinReceipt(
        accountId: String,
        scopeCid: String,
        epoch: UInt64,
        commitHash: Data,
        requestDeviceId: String
    ) throws {
        guard epoch <= UInt64(Int64.max) else {
            throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: scopeCid)
        }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ) ?? (NSEntityDescription.insertNewObject(
                forEntityName: E2eeLocalJoinReceiptDTO.entityName,
                into: context
            ) as! E2eeLocalJoinReceiptDTO)
            let now = Date().bridgeDate
            receipt.accountId = accountId
            receipt.scopeCid = scopeCid
            receipt.epoch = Int64(epoch)
            receipt.commitHash = commitHash
            receipt.requestDeviceId = requestDeviceId
            receipt.status = E2eeLocalJoinReceiptStatus.prepared.rawValue
            receipt.createdAt = now
            receipt.updatedAt = now
            receipt.serverAcceptedAt = nil
            receipt.mergedAt = nil
        }
    }

    func markLocalJoinServerAccepted(accountId: String, scopeCid: String) throws {
        try updateLocalJoinReceipt(accountId: accountId, scopeCid: scopeCid) { receipt, now in
            guard receipt.status == E2eeLocalJoinReceiptStatus.prepared.rawValue ||
                    receipt.status == E2eeLocalJoinReceiptStatus.serverAccepted.rawValue else {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: scopeCid)
            }
            receipt.status = E2eeLocalJoinReceiptStatus.serverAccepted.rawValue
            receipt.serverAcceptedAt = now
        }
    }

    func markLocalJoinMerged(
        accountId: String,
        scopeCid: String,
        firstDecryptableEpoch: UInt64
    ) throws {
        guard firstDecryptableEpoch <= UInt64(Int64.max) else {
            throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: scopeCid)
        }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ), receipt.status == E2eeLocalJoinReceiptStatus.serverAccepted.rawValue ||
                receipt.status == E2eeLocalJoinReceiptStatus.merged.rawValue else {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: scopeCid)
            }
            guard let channelId = try? ChannelId(cid: scopeCid),
                  let channel = context.channel(cid: channelId) else {
                throw ClientError.Unexpected("Missing channel for local join receipt.")
            }
            let now = Date().bridgeDate
            receipt.status = E2eeLocalJoinReceiptStatus.merged.rawValue
            receipt.updatedAt = now
            receipt.mergedAt = now
            channel.mlsFirstDecryptableEpoch = NSNumber(value: firstDecryptableEpoch)
            channel.mlsGroupJoinedAt = now
        }
    }

    func localJoinReceiptProof(accountId: String, scopeCid: String) throws -> LocalJoinReceiptProof? {
        try readAndWait { context in
            guard let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ), receipt.epoch >= 0,
               let status = E2eeLocalJoinReceiptStatus(rawValue: receipt.status) else { return nil }
            return LocalJoinReceiptProof(
                commitHash: receipt.commitHash,
                epoch: UInt64(receipt.epoch),
                requestDeviceId: receipt.requestDeviceId,
                status: status
            )
        }
    }

    func finalizeLocalJoinReceipt(
        accountId: String,
        scopeCid: String,
        commitHash: Data,
        epoch: UInt64,
        deviceId: String
    ) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ) else { return }
            guard receipt.status == E2eeLocalJoinReceiptStatus.merged.rawValue,
                  receipt.commitHash == commitHash,
                  receipt.epoch == Int64(epoch),
                  receipt.requestDeviceId == deviceId else {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: scopeCid)
            }
            receipt.status = E2eeLocalJoinReceiptStatus.finalized.rawValue
            context.delete(receipt)
        }
    }

    /// Atomically advances the exact external-commit cursor, records the installation's join
    /// boundary, and finalizes the matching receipt. The single transaction closes the crash
    /// window where an old implementation advanced a cursor before deleting its receipt.
    func finalizeExternalJoinCommit(
        accountId: String,
        scopeCid: String,
        envelope: E2eSyncEventEnvelope,
        commitHash: Data,
        epoch: UInt64,
        deviceId: String,
        requireReceipt: Bool
    ) throws {
        guard epoch <= UInt64(Int64.max) else {
            throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
        }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            let pending = try E2eeInboxEventDTO.loadFirstPendingTimestampBucket(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ).map { try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope) }
                .sorted(by: E2eSyncEventEnvelope.canonicalScopeSyncOrder)
            if let first = pending.first, first.eventId != envelope.eventId {
                throw E2eeDurableInboxError.outOfOrderApply(
                    expectedEventId: first.eventId,
                    actualEventId: envelope.eventId
                )
            }
            guard let event = try E2eeInboxEventDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                eventId: envelope.eventId,
                context: context
            ), event.protocolCiphertextHash == commitHash,
               event.protocolTargetEpoch == Int64(epoch),
               event.mlsStatePersisted else {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
            }
            let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )
            if let receipt {
                guard receipt.status == E2eeLocalJoinReceiptStatus.merged.rawValue,
                      receipt.commitHash == commitHash,
                      receipt.epoch == Int64(epoch),
                      receipt.requestDeviceId == deviceId else {
                    throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
                }
                receipt.status = E2eeLocalJoinReceiptStatus.finalized.rawValue
                context.delete(receipt)
            } else if requireReceipt {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: envelope.eventId)
            }
            guard let cid = try? ChannelId(cid: scopeCid),
                  let channel = context.channel(cid: cid) else {
                throw ClientError.Unexpected("Missing channel for external-join boundary.")
            }
            event.appliedAt = Date().bridgeDate
            event.failureCategory = nil
            channel.mlsFirstDecryptableEpoch = NSNumber(value: epoch)
            channel.mlsFirstDecryptableCursorCreatedAt = envelope.createdAt.bridgeDate
            channel.mlsFirstDecryptableCursorEventId = envelope.eventId
            let checkpoint = try E2eeSyncCheckpointDTO.loadOrCreate(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )
            checkpoint.setApplyCursor(.init(createdAt: envelope.createdAtRaw, eventId: envelope.eventId))
            let repairs = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
            repairs.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND eventId == %@ AND resolvedAt == nil",
                accountId,
                scopeCid,
                envelope.eventId
            )
            try context.fetch(repairs).forEach { $0.resolvedAt = Date().bridgeDate }
        }
    }

    func localJoinBoundary(accountId: String, scopeCid: String) throws -> E2eSyncEventEnvelope? {
        try readAndWait { context in
            guard let cid = try? ChannelId(cid: scopeCid),
                  let channel = context.channel(cid: cid),
                  let eventId = channel.mlsFirstDecryptableCursorEventId,
                  let event = try E2eeInboxEventDTO.load(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    eventId: eventId,
                    context: context
                  ) else { return nil }
            return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: event.rawEnvelope)
        }
    }

    func discardLocalJoinReceipt(accountId: String, scopeCid: String) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            if let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ) {
                context.delete(receipt)
            }
        }
    }

    /// Completes the only crash window between exact cursor advancement and receipt deletion.
    /// The event proof was written and validated before `markApplied`; therefore an applied row
    /// with the receipt's exact hash/epoch is sufficient to finish the already-proven transition.
    @discardableResult
    func finalizeAppliedLocalJoinReceiptIfPossible(accountId: String, scopeCid: String) throws -> Bool {
        var finalized = false
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ), receipt.status == E2eeLocalJoinReceiptStatus.merged.rawValue else { return }
            let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
            request.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND protocolCiphertextHash == %@ AND protocolTargetEpoch == %lld AND mlsStatePersisted == YES AND appliedAt != nil",
                accountId,
                scopeCid,
                receipt.commitHash as NSData,
                receipt.epoch
            )
            request.fetchLimit = 1
            guard let event = try context.fetch(request).first,
                  let envelope = try? JSONDecoder.default.decode(
                    E2eSyncEventEnvelope.self,
                    from: event.rawEnvelope
                  ),
                  case let .protocol(protocolData) = envelope.event,
                  protocolData.type == .externalCommit,
                  protocolData.user.id == accountId,
                  protocolData.deviceId == receipt.requestDeviceId,
                  let cid = try? ChannelId(cid: scopeCid),
                  let channel = context.channel(cid: cid) else { return }
            receipt.status = E2eeLocalJoinReceiptStatus.finalized.rawValue
            channel.mlsFirstDecryptableEpoch = NSNumber(value: receipt.epoch)
            channel.mlsFirstDecryptableCursorCreatedAt = envelope.createdAt.bridgeDate
            channel.mlsFirstDecryptableCursorEventId = envelope.eventId
            context.delete(receipt)
            finalized = true
        }
        return finalized
    }

    func markApplicationDispositionAndApplied(
        accountId: String,
        scopeCid: String,
        envelope: E2eSyncEventEnvelope,
        disposition: E2eeApplicationDisposition
    ) throws {
        try markApplicationDispositionsAndApplied(
            accountId: accountId,
            scopeCid: scopeCid,
            applications: [(envelope, disposition)]
        )
    }

    /// Commits a consecutive run of non-cryptographic application outcomes in one transaction.
    /// The caller caps runs at the scope-sync page size (100). Every row is still checked against
    /// the canonical pending order before the final cursor is advanced to the last envelope.
    func markApplicationDispositionsAndApplied(
        accountId: String,
        scopeCid: String,
        applications: [(E2eSyncEventEnvelope, E2eeApplicationDisposition)]
    ) throws {
        guard !applications.isEmpty else { return }
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            let appliedAt = Date().bridgeDate
            for (envelope, disposition) in applications {
                let pendingEnvelopes = try E2eeInboxEventDTO.loadFirstPendingTimestampBucket(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    context: context
                ).map { try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope) }
                if let firstPending = pendingEnvelopes.sorted(by: E2eSyncEventEnvelope.canonicalScopeSyncOrder).first,
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
                event.applicationDisposition = disposition.rawValue
                event.appliedAt = appliedAt
                event.failureCategory = nil
            }

            let checkpoint = try E2eeSyncCheckpointDTO.loadOrCreate(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            )
            if let last = applications.last?.0 {
                checkpoint.setApplyCursor(.init(createdAt: last.createdAtRaw, eventId: last.eventId))
            }

            let repairs = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
            repairs.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND eventId IN %@ AND resolvedAt == nil",
                accountId,
                scopeCid,
                applications.map { $0.0.eventId }
            )
            try context.fetch(repairs).forEach { $0.resolvedAt = appliedAt }
        }
    }

    /// Normalizes legacy repair rows after a verified join epoch becomes available. Raw envelopes
    /// and timeline messages remain untouched; only pre-join application classification changes.
    func normalizePreJoinHistoricalApplications(
        accountId: String,
        scopeCid: String,
        firstDecryptableEpoch: Int64,
        joinBoundary: E2eSyncEventEnvelope? = nil
    ) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
            request.predicate = NSPredicate(format: "accountId == %@ AND scopeCid == %@", accountId, scopeCid)
            request.fetchBatchSize = 100
            let resolvedAt = Date().bridgeDate
            for event in try context.fetch(request) {
                guard let envelope = try? JSONDecoder.default.decode(
                    E2eSyncEventEnvelope.self,
                    from: event.rawEnvelope
                ), case .application(let application) = envelope.event,
                   !application.isSystemMessage else { continue }
                let beforeVerifiedBoundary = joinBoundary.map {
                    E2eSyncEventEnvelope.canonicalScopeSyncOrder(envelope, $0)
                } ?? false
                let beforeEpochOnlyBoundary: Bool
                if joinBoundary == nil, let messageEpoch = application.mlsEpoch {
                    beforeEpochOnlyBoundary = messageEpoch < firstDecryptableEpoch
                } else {
                    beforeEpochOnlyBoundary = false
                }
                guard beforeVerifiedBoundary || beforeEpochOnlyBoundary else { continue }
                event.applicationDisposition = E2eeApplicationDisposition.preJoinHistorical.rawValue
                event.failureCategory = nil

                let repairs = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
                repairs.predicate = NSPredicate(
                    format: "accountId == %@ AND scopeCid == %@ AND eventId == %@ AND resolvedAt == nil",
                    accountId,
                    scopeCid,
                    event.eventId
                )
                try context.fetch(repairs).forEach { $0.resolvedAt = resolvedAt }
            }
        }
    }

    func loadApplicationEvents(
        accountId: String,
        scopeCid: String,
        disposition: E2eeApplicationDisposition
    ) throws -> [E2eSyncEventEnvelope] {
        try readAndWait { context in
            let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
            request.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND applicationDisposition == %@",
                accountId,
                scopeCid,
                disposition.rawValue
            )
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \E2eeInboxEventDTO.createdAt, ascending: true),
                NSSortDescriptor(keyPath: \E2eeInboxEventDTO.eventId, ascending: true)
            ]
            request.fetchBatchSize = 100
            return try context.fetch(request).map {
                try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: $0.rawEnvelope)
            }
        }.sorted(by: E2eSyncEventEnvelope.canonicalScopeSyncOrder)
    }

    func updateAppliedApplicationDisposition(
        accountId: String,
        scopeCid: String,
        eventId: String,
        disposition: E2eeApplicationDisposition
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
            ), event.appliedAt != nil else {
                throw E2eeDurableInboxError.eventNotFound(eventId: eventId)
            }
            event.applicationDisposition = disposition.rawValue
            event.failureCategory = nil
            let request = NSFetchRequest<E2eeRepairIssueDTO>(entityName: E2eeRepairIssueDTO.entityName)
            request.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND eventId == %@ AND resolvedAt == nil",
                accountId,
                scopeCid,
                eventId
            )
            let resolvedAt = Date().bridgeDate
            try context.fetch(request).forEach { $0.resolvedAt = resolvedAt }
        }
    }

    private func updateLocalJoinReceipt(
        accountId: String,
        scopeCid: String,
        update: (E2eeLocalJoinReceiptDTO, DBDate) throws -> Void
    ) throws {
        try database.writeAndWait { context in
            guard let context = context as? NSManagedObjectContext else {
                throw ClientError.Unexpected("Core Data writer context is unavailable.")
            }
            guard let receipt = try E2eeLocalJoinReceiptDTO.load(
                accountId: accountId,
                scopeCid: scopeCid,
                context: context
            ) else {
                throw E2eeDurableInboxError.protocolCommitProofMismatch(eventId: scopeCid)
            }
            let now = Date().bridgeDate
            try update(receipt, now)
            receipt.updatedAt = now
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
