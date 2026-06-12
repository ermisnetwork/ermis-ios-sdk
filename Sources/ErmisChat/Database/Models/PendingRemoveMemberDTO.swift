//
// Copyright 2025 Ermis Inc.
//

import CoreData

/// A CoreData entity that tracks members who left a channel via self-remove.
/// When a `selfRemove` member.removed event is received, the member's userId and channelCid
/// are stored here so they can be queried later during add/remove member operations.
@objc(PendingRemoveMemberDTO)
class PendingRemoveMemberDTO: NSManagedObject {
    /// Composite unique key: "\(userId)-\(channelCid)".
    @NSManaged var id: String
    /// The user ID of the member who left.
    @NSManaged var userId: String
    /// The channel CID string (e.g. "messaging:channel-id").
    @NSManaged var channelCid: String
    /// The date this pending removal was recorded.
    @NSManaged var createdAt: DBDate
}

// MARK: - Loading

extension PendingRemoveMemberDTO {
    /// Fetches an existing entry for the given userId + channelCid pair, or returns `nil`.
    static func load(userId: String, channelCid: String, context: NSManagedObjectContext) -> PendingRemoveMemberDTO? {
        let request = NSFetchRequest<PendingRemoveMemberDTO>(entityName: PendingRemoveMemberDTO.entityName)
        request.predicate = NSPredicate(format: "id == %@", pendingId(userId: userId, channelCid: channelCid))
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// Fetches all pending remove member entries for a given channel.
    static func loadAll(channelCid: String, context: NSManagedObjectContext) -> [PendingRemoveMemberDTO] {
        let request = NSFetchRequest<PendingRemoveMemberDTO>(entityName: PendingRemoveMemberDTO.entityName)
        request.predicate = NSPredicate(format: "channelCid == %@", channelCid)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PendingRemoveMemberDTO.createdAt, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// Creates a new entry, or returns the existing one if already present.
    @discardableResult
    static func createOrLoad(userId: String, channelCid: String, context: NSManagedObjectContext) -> PendingRemoveMemberDTO {
        if let existing = load(userId: userId, channelCid: channelCid, context: context) {
            return existing
        }
        let new = NSEntityDescription.insertNewObject(
            forEntityName: PendingRemoveMemberDTO.entityName,
            into: context
        ) as! PendingRemoveMemberDTO
        new.id = pendingId(userId: userId, channelCid: channelCid)
        new.userId = userId
        new.channelCid = channelCid
        new.createdAt = Date().bridgeDate
        return new
    }

    private static func pendingId(userId: String, channelCid: String) -> String {
        "\(userId)-\(channelCid)"
    }
}
