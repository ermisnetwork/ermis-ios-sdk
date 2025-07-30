//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

public struct ComposerContent {
    // Composer text content.
    public let text: String
    // A `ComposerState` rawValue of composer.
    public let state: String
    // Composer text contain mention all user or not.
    public let hasMentionAll: Bool
    // List of mention user in text content.
    public let mentionUsers: Set<ChatUser>
    // The messege that current composer is reply.
    public let quotingMessage: ChatMessage?
    // The message that current composer is reply in thread.
    public let threadMessage: ChatMessage?
    // The message that current user is edit.
    public let editingMessage: ChatMessage?
    // The time what composer content is saved.
    public let createdAt: Date


    public init(text: String,
                state: String,
                hasMentionAll: Bool,
                mentionUsers: Set<ChatUser>,
                quotingMessage: ChatMessage?,
                threadMessage: ChatMessage?,
                editingMessage: ChatMessage?,
                createdAt: Date) {
        self.text = text
        self.state = state
        self.hasMentionAll = hasMentionAll
        self.mentionUsers = mentionUsers
        self.quotingMessage = quotingMessage
        self.threadMessage = threadMessage
        self.editingMessage = editingMessage
        self.createdAt = createdAt
    }
}

extension ComposerContent: Equatable {
    
}
