//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public protocol PreviewMessageProvider {
    /// The message preview text in case the message is empty.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForEmptyMessage() -> String

    /// The message preview text in case the message is an audio recording message.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageForAudioRecordingMessage(messageText: String) -> String

    /// The message preview text in case the message's type is system.
    /// - Parameter messageText: The current text of the message.
    /// - Parameter channel: The channel of this message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForSystemMessage(messageText: String, in channel: Channel) -> String

    /// The message preview text in case the message's type is signal.
    /// - Parameter messageText: The current text of the message.
    /// - Parameter channel: The channel of this message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForCallMessage(messageText: String, in channel: Channel) -> String

    /// The message preview text in case the message is a search result.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForSearchedMessage(messageText: String) -> String

    /// The message preview text in case the message is from the current user.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForCurrentUser(messageText: String) -> String

    /// The message preview text in case the message is a 1on1 channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextFor1on1Channel(messageText: String) -> String

    /// The message preview text in case the message is from another user and it is not a 1on1 channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextFromAnotherUser(_ user: ChatUser, messageText: String) -> String

    /// The message preview text in case the message is translated.
    /// - Parameter previewMessage: The preview message of the channel.
    /// - Parameter channel: The channel of this message.
    /// - Parameter messageText: The current text of the message.
    /// - Returns: A string representing the message preview text.
    func translatedPreviewText(for previewMessage: ChatMessage, in channel: Channel, messageText: String) -> String?

    /// The message preview text in case it contains attachments.
    /// - Parameter previewMessage: The preview message of the channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns: A string representing the message preview text.
    func attachmentPreviewText(for previewMessage: ChatMessage, messageText: String) -> String?
}
// Default implement of preview message provider.
public extension PreviewMessageProvider where Self: FormattersProvider {
    /// The message preview text in case the message is empty.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForEmptyMessage() -> String {
        L10n.Channel.Item.emptyMessages
    }

    /// The message preview text in case the message is an audio recording message.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageForAudioRecordingMessage(messageText: String) -> String {
        L10n.ChannelList.Preview.Voice.recording
    }

    /// The message preview text in case the message's type is system.
    /// - Parameters:
    ///  - messageText: The current text of the message.
    ///  - channel: The current channel of this message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForSystemMessage(messageText: String, in channel: Channel) -> String {
        let systemMessage = SystemMessage(systemMessage: messageText)
        return self.formatters.systemMessage.format(systemMessage: systemMessage, in: channel) ?? messageText
    }

    /// The message preview text in case the message's type is sticker.
    /// - Parameter channel: The current channel of this message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForStickerMessage(in channel: Channel) -> String {
        return L10n.ChannelList.Preview.sticker
    }

    /// The message preview text in case the message's type is signal.
    /// - Parameters:
    ///  - messageText: The current text of the message.
    ///  - channel: The current channel of this message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForCallMessage(messageText: String, in channel: Channel) -> String {
        let callMessage = SignalMessage(signalMessage: messageText)
        return self.formatters.signalMessage.format(signalMessage: callMessage, in: channel) ?? messageText
    }

    /// The message preview text in case the message is a search result.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForSearchedMessage(messageText: String) -> String {
        messageText
    }

    /// The message preview text in case the message is from the current user.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextForCurrentUser(messageText: String) -> String {
        "\(L10n.you): \(messageText)"
    }

    /// The message preview text in case the message is a 1on1 channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextFor1on1Channel(messageText: String) -> String {
        messageText
    }

    /// The message preview text in case the message is from another user and it is not a 1on1 channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    func previewMessageTextFromAnotherUser(_ user: ChatUser, messageText: String) -> String {
        let authorName = user.name ?? user.id
        return "\(authorName): \(messageText)"
    }

    /// The message preview text in case the message is translated.
    /// - Parameter previewMessage: The preview message of the channel.
    /// - Parameter channel: The channel of this message.
    /// - Parameter messageText: The current text of the message.
    /// - Returns: A string representing the message preview text.
    func translatedPreviewText(for previewMessage: ChatMessage, in channel: Channel, messageText: String) -> String? {
        guard let currentUserLang = channel.membership?.language,
              let translatedText = previewMessage.translatedText(for: currentUserLang) else {
            return nil
        }
        return translatedText
    }

    /// The message preview text in case it contains attachments.
    /// - Parameter previewMessage: The preview message of the channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns: A string representing the message preview text.
    func attachmentPreviewText(for previewMessage: ChatMessage, messageText: String) -> String? {
        guard let attachment = previewMessage.allAttachments.first else {
            return nil
        }
        let text = messageText
        switch attachment.type {
        case .audio:
            let defaultAudioText = L10n.Channel.Item.audio
            return "🎧 \(text.isEmpty ? defaultAudioText : text)"
        case .file:
            guard let fileAttachment = previewMessage.fileAttachments.first else {
                return nil
            }
            let title = fileAttachment.payload.title
            return "📄 \(title ?? text)"
        case .image:
            let defaultPhotoText = L10n.Channel.Item.photo
            return "📷 \(text.isEmpty ? defaultPhotoText : text)"
        case .video:
            let defaultVideoText = L10n.Channel.Item.video
            return "📹 \(text.isEmpty ? defaultVideoText : text)"
        default:
            return nil
        }
    }
}
