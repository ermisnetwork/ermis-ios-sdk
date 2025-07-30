//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

@objc(ComposerContentDTO)
final class ComposerContentDTO: NSManagedObject {
    @NSManaged var text: String
    @NSManaged var state: String
    @NSManaged var hasMentionAll: Bool
    @NSManaged var threadMessage: MessageDTO?
    @NSManaged var quotingMessage: MessageDTO?
    @NSManaged var editingMessage: MessageDTO?
    @NSManaged var createdAt: DBDate
    @NSManaged var mentionUsers: Set<UserDTO>

    func asModel() throws -> ComposerContent {
        .init(text: text,
              state: state,
              hasMentionAll: hasMentionAll,
              mentionUsers: Set(mentionUsers.compactMap({ try? $0.asModel()})),
              quotingMessage: try quotingMessage?.asModel(),
              threadMessage: try threadMessage?.asModel(),
              editingMessage: try editingMessage?.asModel(),
              createdAt: createdAt.bridgeDate)
    }
}

extension ComposerContent {
    func asDTO(context: NSManagedObjectContext, projectId: String) -> ComposerContentDTO {
        let dto = ComposerContentDTO(context: context)
        dto.text = text
        dto.state = state
        dto.hasMentionAll = hasMentionAll
        dto.createdAt = createdAt.bridgeDate
        if let quotingMessage {
            dto.quotingMessage = context.message(id: quotingMessage.id)
        }
        if let threadMessage {
            dto.threadMessage = context.message(id: threadMessage.id)
        }
        if let editingMessage {
            dto.editingMessage = context.message(id: editingMessage.id)
        }
        for mentionUser in mentionUsers {
            if let user = context.user(id: mentionUser.userId, projectId: projectId) {
                dto.mentionUsers.insert(user)
            }
        }
        return dto
    }
}


