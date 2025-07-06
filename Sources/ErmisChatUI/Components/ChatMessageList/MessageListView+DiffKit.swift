//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

extension MessageListView {
    internal func reloadMessages(
        previousSnapshot: [ChatMessage],
        newSnapshot: [ChatMessage],
        with animation: @autoclosure () -> RowAnimation,
        completion: (() -> Void)? = nil
    ) {
        let changeset = StagedChangeset(
            source: previousSnapshot,
            target: newSnapshot
        )
        // This is need because DiffKit doesn't provide a completion block for when the reload is finished.
        // The CATransaction notifies when animations are finished executing between begin() and commit().
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        reload(
            using: changeset,
            with: animation()
        ) { [weak self] newMessages in
            self?.onNewDataSource?(newMessages)
        }
        CATransaction.commit()
    }
}

extension ChatMessage: Differentiable {
    public func isContentEqual(to source: ChatMessage) -> Bool {
        id == source.id
            && updatedAt == source.updatedAt
            && replyCount == source.replyCount
            && isShadowed == source.isShadowed
            && text == source.text
            && textUpdatedAt == source.textUpdatedAt
            && localState == source.localState
            && type == source.type
            && command == source.command
            && arguments == source.arguments
            && parentMessageId == source.parentMessageId
            && isFlaggedByCurrentUser == source.isFlaggedByCurrentUser
            && reactionCounts == source.reactionCounts
            && reactionScores == source.reactionScores
            && translations == source.translations
            && currentUserReactionsCount == source.currentUserReactionsCount
            && threadParticipantsCount == source.threadParticipantsCount
            && readByCount == source.readByCount
            && quotedMessage == source.quotedMessage
            && author == source.author
            && allAttachments == source.allAttachments
    }
}

extension ChatMessage: Equatable {
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.isContentEqual(to: rhs)
    }
}
