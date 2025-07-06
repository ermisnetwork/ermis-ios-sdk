//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

/// Resolves layout options for the message at given `indexPath`.
open class MessageLayoutOptionsResolver {
    /// The maximum time interval between 2 consecutive messages sent by the same user to treat them as a single message group.
    public let maxTimeIntervalBetweenMessagesInGroup: TimeInterval

    // TODO: Propagate via `init` in v5, make it non-optional.
    /// The config of the `ErmisClient` used.
    public internal(set) var config: ErmisClientConfig?
    /// The components config in use.
    public internal(set) var components: Components?

    /// Creates new `MessageLayoutOptionsResolver`.
    ///
    /// - Parameter maxTimeIntervalBetweenMessagesInGroup: The maximum time interval between 2 consecutive messages sent by the same user to treat them as a single message group (`60 sec` by default).
    public init(maxTimeIntervalBetweenMessagesInGroup: TimeInterval = 60) {
        self.maxTimeIntervalBetweenMessagesInGroup = maxTimeIntervalBetweenMessagesInGroup
    }

    /// Calculates layout options for the message.
    /// - Parameters:
    ///   - indexPath: The index path of the cell displaying the message.
    ///   - channel: The channel message is related to.
    ///   - messages: The list of messages in the channel.
    ///   - theme: The theme theme in use.
    /// - Returns: The layout options describing the components and layout of message content view.
    open func optionsForMessage(
        at indexPath: IndexPath,
        in channel: Channel,
        with messages: AnyRandomAccessCollection<ChatMessage>,
        theme: Theme
    ) -> MessageLayoutOptions {
        // Make sure the message exists. Sometimes when switching channels really fast on iPad's split view,
        // it can happen that this method is called for old data from a previous channel.
        guard indexPath.item < messages.count else {
            return []
        }

        let messageIndex = messages.index(messages.startIndex, offsetBy: indexPath.item)
        let message = messages[messageIndex]

        let isFirstInSequence = isMessageFirstInSequence(
            messageIndexPath: indexPath,
            messages: messages
        )

        let isLastInSequence = isMessageLastInSequence(
            messageIndexPath: indexPath,
            messages: messages
        )

        let isEdited = message.textUpdatedAt != nil && message.type != .system

        var options: MessageLayoutOptions = []

        if message.shouldRenderAsSystemMessage {
            return [.text, .centered]
        }

        // Do not show bubble if the message is to be rendered as large emoji.
        // Unless we are quoting a message, in this case the bubble should still be rendered.
        if !message.shouldRenderAsJumbomoji || message.quotedMessage != nil {
            options.insert(.bubble)
        }

        if message.isSentByCurrentUser {
            options.insert(.flipped)
        }
        if isFirstInSequence {
            options.insert(.firstSequenceBubble)
        } else if isLastInSequence {
            options.insert(.lastSequenceBubble)
        } else {
            options.insert(.continuousBubble)
        }
 
        if !isLastInSequence && !message.isSentByCurrentUser {
            options.insert(.avatarSizePadding)
        }
        if isLastInSequence {
            options.insert(.timestamp)
        }
        if isEdited && message.type != .signal {
            options.insert(.showEditedHistory)
        }
        if showOnlyVisibleToYouIndicator(for: message) {
            options.insert(.onlyVisibleToYouIndicator)
        }
        if message.textContent?.isEmpty == false && message.type != .signal {
            options.insert(.text)
        }
        if isLastInSequence && !message.isSentByCurrentUser {
            options.insert(.avatar)
        }
        if isLastInSequence && !message.isSentByCurrentUser && channel.memberCount > 2 {
            options.insert(.authorName)
        }
        if (channel.config?.repliesEnabled ?? true) && (message.isRootOfThread || message.isPartOfThread) {
            options.insert(.threadInfo)
            // The bubbles with thread look like continuous bubbles
            options.insert(.continuousBubble)
        }

        guard message.isDeleted == false else {
            return options
        }

        if shouldRenderTranslation(message: message, channel: channel) {
            options.insert(.translation)
        }

        if hasQuotedMessage(message) {
            options.insert(.quotedMessage)
        }
        if hasReactions(channel, message, theme) {
            options.insert(.reactions)
        }
        if message.isLastActionFailed {
            options.insert(.errorIndicator)
        }
        if isLastInSequence && canShowDeliveryStatus(for: message, in: channel) {
            options.insert(.deliveryStatusIndicator)
        }

        return options
    }

    /// Says whether the message at given `indexPath` is the first one in a sequence of messages
    /// sent by a single user where the time delta between near by messages
    /// is `<= maxTimeIntervalBetweenMessagesInGroup`.
    ///
    /// Returns `true` if one of the following conditions is met:
    ///     1. the message at `messageIndexPath` is the last one in the channel
    ///     2. the message sent before the message at `messageIndexPath` has different author
    ///     3. the message sent before the message at `messageIndexPath` has the same author but the
    ///     time delta between messages is bigger than `maxTimeIntervalBetweenMessagesInGroup`
    ///     4. the message sent before the message at `messageIndexPath` is of `error` type
    ///
    /// - Parameters:
    ///   - messageIndexPath: The index path of the target message.
    ///   - messages: The list of loaded channel messages.
    /// - Returns: Returns `true` if the message start the sequence of messages from a single author.
    open func isMessageFirstInSequence(
        messageIndexPath: IndexPath,
        messages: AnyRandomAccessCollection<ChatMessage>
    ) -> Bool {
        let messageIndex = messages.index(messages.startIndex, offsetBy: messageIndexPath.item)
        guard let message = messages[safe: messageIndex] else {
            indexNotFoundAssertion()
            return true
        }

        // The current message is the last message so it's either a standalone or last in sequence.
        guard messageIndexPath.item != messages.count - 1 else { return true }

        let previousMessageIndex = messages.index(after: messageIndex)
        guard let previousMessage = messages[safe: previousMessageIndex] else {
            indexNotFoundAssertion()
            return true
        }

        guard
            previousMessage.type != .error,
            previousMessage.type != .ephemeral,
            previousMessage.type != .system
        else { return true }

        let previousMessageIndexPath = IndexPath(row: messages.distance(from: messages.startIndex,
                                                                        to: previousMessageIndex),
                                                 section: messageIndexPath.section)
        return isMessageLastInSequence(messageIndexPath: previousMessageIndexPath, messages: messages)
    }

    /// Says whether the message at given `indexPath` is the last one in a sequence of messages
    /// sent by a single user where the time delta between near by messages
    /// is `<= maxTimeIntervalBetweenMessagesInGroup`.
    ///
    /// Returns `true` if one of the following conditions is met:
    ///     1. the message at `messageIndexPath` is the most recent one in the channel
    ///     2. the message sent after the message at `messageIndexPath` has different author
    ///     3. the message sent after the message at `messageIndexPath` has the same author but the
    ///     time delta between messages is bigger than `maxTimeIntervalBetweenMessagesInGroup`
    ///     4. the message sent after the message at `messageIndexPath` is of `error` type
    ///
    /// - Parameters:
    ///   - messageIndexPath: The index path of the target message.
    ///   - messages: The list of loaded channel messages.
    /// - Returns: Returns `true` if the message ends the sequence of messages from a single author.
    open func isMessageLastInSequence(
        messageIndexPath: IndexPath,
        messages: AnyRandomAccessCollection<ChatMessage>
    ) -> Bool {
        let messageIndex = messages.index(messages.startIndex, offsetBy: messageIndexPath.item)
        guard let message = messages[safe: messageIndex] else {
            indexNotFoundAssertion()
            return true
        }

        // The current message is the last message so it's either a standalone or last in sequence.
//        guard messageIndexPath.item > 0 else { return true }

        let nextMessageIndex = messages.index(before: messageIndex)
        guard let nextMessage = messages[safe: nextMessageIndex] else {
            indexNotFoundAssertion()
            return true
        }

        // If message was edited, always break the grouping of messages.
        if components?.isMessageEditedLabelEnabled == true && message.textUpdatedAt != nil {
            return true
        }

        // The message after the current one has different author so the current message
        // is either a standalone or last in sequence.
        guard nextMessage.author == message.author else { return true }

        // The current message should end the group when the next message has type:
        //  1. `error` (e.g. contains invalid command/didn't pass moderation)
        //  2. `ephemeral`
        //  3. `system`
        guard
            nextMessage.type != .error,
            nextMessage.type != .ephemeral,
            nextMessage.type != .system
        else { return true }

        let delay = nextMessage.createdAt.timeIntervalSince(message.createdAt)

        // If the message next to the current one is sent with delay > maxTimeIntervalBetweenMessagesInGroup,
        // the current message ends the sequence.
        return delay > maxTimeIntervalBetweenMessagesInGroup
    }

    /// Determines whether to populate `onlyVisibleToYouIndicator` for the given message.
    /// - Parameter message: The message.
    /// - Returns: `true` if `onlyVisibleToYouIndicator` layout option should be included for the given message.
    open func showOnlyVisibleToYouIndicator(for message: ChatMessage) -> Bool {
        guard message.isSentByCurrentUser else {
            return false
        }

        switch message.type {
        case .ephemeral:
            return true
        case .deleted:
            guard let config = config else {
                log.assertionFailure("The `config` property must be assiged at this point.")
                return false
            }

            return config.deletedMessagesVisibility == .visibleForCurrentUser
        default:
            return false
        }
    }

    /// Makes a decision to show the delivery status for the given message in the given channel.
    ///
    /// - Parameters:
    ///   - message: The message to show a delivery status for.
    ///   - channel: The channel the message is sent to.
    /// - Returns: `true` if delivery status should be shown.
    open func canShowDeliveryStatus(for message: ChatMessage, in channel: Channel) -> Bool {
        guard let status = message.deliveryStatus else { return false }

        switch status {
        case .pending:
            return true
        case .sent, .read:
            // TODO: - Check Config
            return channel.config?.readEventsEnabled ?? true
        default:
            return false
        }
    }
}

// MARK: Helpers

private extension MessageLayoutOptionsResolver {
    func hasQuotedMessage(_ message: ChatMessage) -> Bool {
        message.quotedMessage?.id != nil
    }

    func hasReactions(_ channel: Channel, _ message: ChatMessage, _ theme: Theme) -> Bool {
        if !(channel.config?.reactionsEnabled ?? true) {
            return false
        }

        if message.reactionScores.isEmpty {
            return false
        }

        let unhandledReactionTypes = message.latestReactions.filter { theme.icons.availableReactions[$0.type] == nil }
            .map(\.type)

        if !unhandledReactionTypes.isEmpty {
            log.warning("message contains unhandled reaction types \(unhandledReactionTypes)")
        }

        return !message.latestReactions.filter { theme.icons.availableReactions[$0.type] != nil }.isEmpty
    }

    func shouldRenderTranslation(message: ChatMessage, channel: Channel) -> Bool {
        guard components?.messageAutoTranslationEnabled == true else {
            return false
        }

        guard let currentUserLang = channel.membership?.language else {
            return false
        }

        return message.translatedText(for: currentUserLang) != nil
    }
}
