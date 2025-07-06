//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(MessageEditHistoryDTO)
class MessageEditHistoryDTO: NSManagedObject {
    @NSManaged var text: String
    @NSManaged var createdAt: Date
    @NSManaged var message: MessageDTO
}

extension MessageEditHistoryDTO {
    static func create(
        from payload: MessageEditHistoryPayload,
        messageId: String,
        context: NSManagedObjectContext
    ) -> MessageEditHistoryDTO {
        let request = NSFetchRequest<MessageEditHistoryDTO>(
            entityName: MessageEditHistoryDTO.entityName
        )
        let new = NSEntityDescription.insertNewObject(into: context, for: request)
        new.text = payload.text
        new.createdAt = payload.createdAt
        return new
    }

    
}

extension MessageEditHistoryDTO {
    /// Snapshots the current state of `MessageDTO` and returns an immutable model object from it.
    func asModel() -> MessageEditHistory { .init(fromDTO: self) }
}

private
extension MessageEditHistory {
    init(fromDTO dto: MessageEditHistoryDTO) {
        text = dto.text
        createdAt = dto.createdAt
    }
}

