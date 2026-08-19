//
// Copyright 2026 Ermis Inc.
//

import CoreData
import Foundation

enum E2eeDurableInboxError: Error, Equatable {
    case backlogLimitExceeded(scopeCid: String, scopePending: Int, accountPending: Int)
    case duplicateEventPayloadMismatch(eventId: String)
    case eventNotFound(eventId: String)
    case invalidPagination(scopeCid: String)
    case invalidRemovedPagination
    case outOfOrderApply(expectedEventId: String, actualEventId: String)
    case pageTooLarge(scopeCid: String, rawBytes: Int, maximumRawBytes: Int)
    case protocolCommitProofMismatch(eventId: String)
}

@objc(E2eeInboxEventDTO)
final class E2eeInboxEventDTO: NSManagedObject {
    @NSManaged var accountId: String
    @NSManaged var scopeCid: String
    @NSManaged var eventId: String
    @NSManaged var createdAt: DBDate
    @NSManaged var rawEnvelope: Data
    @NSManaged var plaintextPersisted: Bool
    @NSManaged var mlsStatePersisted: Bool
    @NSManaged var appliedAt: DBDate?
    @NSManaged var failureCategory: String?
    @NSManaged var applicationDisposition: String?
    @NSManaged var protocolCiphertextHash: Data?
    @NSManaged var protocolTargetEpoch: Int64

    static func load(
        accountId: String,
        scopeCid: String,
        eventId: String,
        context: NSManagedObjectContext
    ) throws -> E2eeInboxEventDTO? {
        let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: entityName)
        request.predicate = NSPredicate(
            format: "accountId == %@ AND scopeCid == %@ AND eventId == %@",
            accountId,
            scopeCid,
            eventId
        )
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    static func loadPending(
        accountId: String,
        scopeCid: String,
        context: NSManagedObjectContext
    ) throws -> [E2eeInboxEventDTO] {
        let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: entityName)
        request.predicate = NSPredicate(
            format: "accountId == %@ AND scopeCid == %@ AND appliedAt == nil",
            accountId,
            scopeCid
        )
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \E2eeInboxEventDTO.createdAt, ascending: true),
            NSSortDescriptor(keyPath: \E2eeInboxEventDTO.eventId, ascending: true)
        ]
        return try context.fetch(request)
    }

    /// Loads only the earliest pending timestamp bucket. Bellboy's secondary kind rank cannot be
    /// expressed by a Core Data sort descriptor because it lives inside the durable envelope, but
    /// decoding the whole backlog for every cursor advance would turn a page apply into quadratic
    /// JSON work. The bucket is the smallest set that needs the in-memory kind-rank comparator.
    static func loadFirstPendingTimestampBucket(
        accountId: String,
        scopeCid: String,
        context: NSManagedObjectContext
    ) throws -> [E2eeInboxEventDTO] {
        let firstRequest = NSFetchRequest<E2eeInboxEventDTO>(entityName: entityName)
        firstRequest.predicate = NSPredicate(
            format: "accountId == %@ AND scopeCid == %@ AND appliedAt == nil",
            accountId,
            scopeCid
        )
        firstRequest.sortDescriptors = [
            NSSortDescriptor(keyPath: \E2eeInboxEventDTO.createdAt, ascending: true)
        ]
        firstRequest.fetchLimit = 1
        guard let first = try context.fetch(firstRequest).first else { return [] }

        let bucketRequest = NSFetchRequest<E2eeInboxEventDTO>(entityName: entityName)
        bucketRequest.predicate = NSPredicate(
            format: "accountId == %@ AND scopeCid == %@ AND appliedAt == nil AND createdAt == %@",
            accountId,
            scopeCid,
            first.createdAt
        )
        return try context.fetch(bucketRequest)
    }

    static func pendingCount(
        accountId: String,
        scopeCid: String? = nil,
        context: NSManagedObjectContext
    ) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        if let scopeCid {
            request.predicate = NSPredicate(
                format: "accountId == %@ AND scopeCid == %@ AND appliedAt == nil",
                accountId,
                scopeCid
            )
        } else {
            request.predicate = NSPredicate(
                format: "accountId == %@ AND appliedAt == nil",
                accountId
            )
        }
        return try context.count(for: request)
    }

    @discardableResult
    static func insertIfNeeded(
        accountId: String,
        scopeCid: String,
        envelope: E2eSyncEventEnvelope,
        context: NSManagedObjectContext
    ) throws -> E2eeInboxEventDTO {
        if let existing = try load(
            accountId: accountId,
            scopeCid: scopeCid,
            eventId: envelope.eventId,
            context: context
        ) {
            let canonicalStoredEnvelope = try E2eeWireJSONCanonicalizer.canonicalizeJSONData(
                existing.rawEnvelope
            )
            guard canonicalStoredEnvelope == envelope.rawEnvelope else {
                throw E2eeDurableInboxError.duplicateEventPayloadMismatch(eventId: envelope.eventId)
            }
            if existing.rawEnvelope != canonicalStoredEnvelope {
                existing.rawEnvelope = canonicalStoredEnvelope
            }
            return existing
        }

        let event = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as! E2eeInboxEventDTO
        event.accountId = accountId
        event.scopeCid = scopeCid
        event.eventId = envelope.eventId
        event.createdAt = envelope.createdAt.bridgeDate
        event.rawEnvelope = envelope.rawEnvelope
        event.plaintextPersisted = false
        event.mlsStatePersisted = false
        event.protocolTargetEpoch = -1
        return event
    }
}

enum E2eeApplicationDisposition: String {
    case pendingGroup = "pending_group"
    case preJoinHistorical = "pre_join_historical"
    case decrypted
}

enum E2eeLocalJoinReceiptStatus: String {
    case prepared
    case serverAccepted
    case merged
    case finalized
}

@objc(E2eeLocalJoinReceiptDTO)
final class E2eeLocalJoinReceiptDTO: NSManagedObject {
    @NSManaged var accountId: String
    @NSManaged var scopeCid: String
    @NSManaged var epoch: Int64
    @NSManaged var commitHash: Data
    @NSManaged var requestDeviceId: String
    @NSManaged var status: String
    @NSManaged var createdAt: DBDate
    @NSManaged var updatedAt: DBDate
    @NSManaged var serverAcceptedAt: DBDate?
    @NSManaged var mergedAt: DBDate?

    static func load(
        accountId: String,
        scopeCid: String,
        context: NSManagedObjectContext
    ) throws -> E2eeLocalJoinReceiptDTO? {
        let request = NSFetchRequest<E2eeLocalJoinReceiptDTO>(entityName: entityName)
        request.predicate = NSPredicate(format: "accountId == %@ AND scopeCid == %@", accountId, scopeCid)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

@objc(E2eeSyncCheckpointDTO)
final class E2eeSyncCheckpointDTO: NSManagedObject {
    static let removedScope = "__removed_channels__"

    @NSManaged var accountId: String
    @NSManaged var scopeCid: String
    @NSManaged var fetchCreatedAt: String?
    @NSManaged var fetchEventId: String?
    @NSManaged var applyCreatedAt: String?
    @NSManaged var applyEventId: String?
    @NSManaged var removedAt: String?
    @NSManaged var removedEventId: String?
    @NSManaged var updatedAt: DBDate

    static func load(
        accountId: String,
        scopeCid: String,
        context: NSManagedObjectContext
    ) throws -> E2eeSyncCheckpointDTO? {
        let request = NSFetchRequest<E2eeSyncCheckpointDTO>(entityName: entityName)
        request.predicate = NSPredicate(format: "accountId == %@ AND scopeCid == %@", accountId, scopeCid)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    static func loadOrCreate(
        accountId: String,
        scopeCid: String,
        context: NSManagedObjectContext
    ) throws -> E2eeSyncCheckpointDTO {
        if let existing = try load(accountId: accountId, scopeCid: scopeCid, context: context) {
            return existing
        }
        let checkpoint = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as! E2eeSyncCheckpointDTO
        checkpoint.accountId = accountId
        checkpoint.scopeCid = scopeCid
        checkpoint.updatedAt = Date().bridgeDate
        return checkpoint
    }

    var fetchCursor: ScopeSyncCursorPayload? {
        guard let fetchCreatedAt, let fetchEventId else { return nil }
        return ScopeSyncCursorPayload(createdAt: fetchCreatedAt, eventId: fetchEventId)
    }

    var applyCursor: ScopeSyncCursorPayload? {
        guard let applyCreatedAt, let applyEventId else { return nil }
        return ScopeSyncCursorPayload(createdAt: applyCreatedAt, eventId: applyEventId)
    }

    var removedCursor: RemovedSyncCursorPayload? {
        guard let removedAt, let removedEventId else { return nil }
        return RemovedSyncCursorPayload(removedAt: removedAt, eventId: removedEventId)
    }

    func setFetchCursor(_ cursor: ScopeSyncCursorPayload) {
        fetchCreatedAt = cursor.createdAt
        fetchEventId = cursor.eventId
        updatedAt = Date().bridgeDate
    }

    func setApplyCursor(_ cursor: ScopeSyncCursorPayload) {
        applyCreatedAt = cursor.createdAt
        applyEventId = cursor.eventId
        updatedAt = Date().bridgeDate
    }

    func setRemovedCursor(_ cursor: RemovedSyncCursorPayload) {
        removedAt = cursor.removedAt
        removedEventId = cursor.eventId
        updatedAt = Date().bridgeDate
    }
}

@objc(E2eeRepairIssueDTO)
final class E2eeRepairIssueDTO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var accountId: String
    @NSManaged var scopeCid: String
    @NSManaged var eventId: String?
    @NSManaged var category: String
    @NSManaged var details: String?
    @NSManaged var createdAt: DBDate
    @NSManaged var resolvedAt: DBDate?

    @discardableResult
    static func create(
        accountId: String,
        scopeCid: String,
        eventId: String?,
        category: String,
        details: String?,
        context: NSManagedObjectContext
    ) -> E2eeRepairIssueDTO {
        let issue = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as! E2eeRepairIssueDTO
        issue.id = UUID().uuidString
        issue.accountId = accountId
        issue.scopeCid = scopeCid
        issue.eventId = eventId
        issue.category = category
        issue.details = details
        issue.createdAt = Date().bridgeDate
        return issue
    }
}
