//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public extension ChatMessage {
    /// A boolean value that checks if actions are available on the message (e.g. `edit`, `delete`, `resend`, etc.).
    var isInteractionEnabled: Bool {
        if type == .ephemeral || isDeleted || shouldRenderAsSystemMessage || type == .signal {
            return false
        }

        // Local delivery/edit states belong only to messages authored by the current user. If a
        // legacy/corrupt row attached one to a remote message, keep normal reply/copy actions
        // available instead of treating that message as a failed local mutation.
        if !isSentByCurrentUser {
            return true
        }

        return localState == nil || isLastActionFailed
    }

    /// The state used by the message-actions menu. A foreign message is always handled as an
    /// authoritative server message; its stale local state must not expose Edit/Delete/Resend.
    var effectiveLocalStateForMessageActions: LocalMessageState? {
        isSentByCurrentUser ? localState : nil
    }

    /// Resolves message ownership from the authoritative user models available to the action
    /// controller. This intentionally does not trust only `isSentByCurrentUser`, because an older
    /// cached snapshot can carry a stale value while the active project user is already known.
    func isAuthoredByCurrentUser(_ currentUser: CurrentChatUser) -> Bool {
        author.id == currentUser.id && author.projectId == currentUser.projectId
    }

    /// The local state used by an action menu that has access to the active project user.
    /// Foreign messages always enter the normal Reply/Copy/Forward action lane.
    func effectiveLocalStateForMessageActions(
        currentUser: CurrentChatUser
    ) -> LocalMessageState? {
        isAuthoredByCurrentUser(currentUser) ? localState : nil
    }

    /// A boolean value that checks if the last action (`send`, `edit` or `delete`) on the message failed.
    var isLastActionFailed: Bool {
        guard isDeleted == false, isSentByCurrentUser else {
            return false
        }

        if isBounced {
            return true
        }

        switch localState {
        case .sendingFailed, .syncingFailed, .deletingFailed:
            return true
        default:
            return false
        }
    }

    /// A boolean value that checks if the message is the root of a thread.
    var isRootOfThread: Bool {
        replyCount > 0 || !latestReplies.isEmpty
    }

    /// A boolean value that checks if the message is part of a thread.
    var isPartOfThread: Bool {
        parentMessageId != nil
    }

    /// The text which should be shown in a text view inside the message bubble.
    var textContent: String? {
        guard type != .ephemeral else {
            return nil
        }

        guard !isDeleted else {
            return L10n.Message.deletedMessagePlaceholder
        }

        guard !isEncrypted else {
            return L10n.Message.encryptedMessage
        }

        return text
    }

    /// Returns last active thread participant.
    var lastActiveThreadParticipant: ChatUser? {
        func sortingCriteriaDate(_ user: ChatUser) -> Date {
            user.lastActiveAt ?? user.userUpdatedAt ?? Date()
        }

        return threadParticipants
            .sorted(by: { sortingCriteriaDate($0) > sortingCriteriaDate($1) })
            .first
    }

    /// A boolean value that says if the message is deleted.
    var isDeleted: Bool {
        deletedAt != nil
    }

    /// A boolean value that determines whether the text message should be rendered as large emojis
    ///
    /// By default, any string which comprises of ONLY emojis of length 3 or less is displayed as large emoji
    ///
    /// Note that for messages sent with attachments, large emojis aren's rendered
    var shouldRenderAsJumbomoji: Bool {
        guard attachmentCounts.isEmpty, let textContent = textContent, !textContent.isEmpty else { return false }
        return textContent.count <= 3 && textContent.containsOnlyEmoji
    }

    var shouldRenderAsSystemMessage: Bool {
        type == .system || (type == .error && isBounced == false)
    }

    /// When a message that has been synced gets edited but is bounced by the moderation API it will return true to this state.
    var failedToBeEditedDueToModeration: Bool {
        localState == .syncingFailed && isBounced == true
    }

    /// When a message fails to get synced because it was bounced by the moderation API it will return true to this state.
    var failedToBeSentDueToModeration: Bool {
        localState == .sendingFailed && isBounced == true
    }

    /// A boolean true if message has contain mention.
    public var hasMentions: Bool { !mentionedUsers.isEmpty || mentionedAll }

    /// Text content after change mention user's Id by mention user's name
    public var textContentAfterParseMention: String? {
        guard !mentionedUsers.isEmpty else {
            return nil
        }
        var text = self.textContent
        for mentionedUser in self.mentionedUsers {
            let ranges = text?.ranges(of: mentionedUser.mentionString).reversed()
            ranges?.forEach { text?.replaceSubrange($0, with: mentionedUser.mentionsDisplayString) }
        }
        return text
    }
}
