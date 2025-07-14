//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

/// A unique identifier of a message.
public typealias MessageId = String

/// A type representing a chat message. `ChatMessage` is an immutable snapshot of a chat message entity at the given time.
public struct ChatMessage {
    /// A unique identifier of the message.
    public let id: MessageId

    /// The ChannelId this message belongs to. This value can be temporarily `nil` for messages that are being removed from
    /// the local cache, or when the local cache is in the process of invalidating.
    public let cid: ChannelId?

    /// The text of the message.
    public let text: String

    public let oldTexts: [MessageEditHistory]?

    /// A type of the message.
    public let type: MessageType

    /// If the message was created by a specific `/` command, the command is saved in this variable.
    public let command: String?

    /// Date when the message was created on the server. This date can differ from `locallyCreatedAt`.
    public let createdAt: Date

    /// Date when the message was created locally and scheduled to be send. Applies only for the messages of the current user.
    public let locallyCreatedAt: Date?

    /// A date when the message was updated last time. This includes any action to the message, like reactions.
    public let updatedAt: Date

    /// If the message was deleted, this variable contains a timestamp of that event, otherwise `nil`.
    public let deletedAt: Date?

    /// The date when the message text, and only the text, was edited. `Nil` if it was not edited.
    public let textUpdatedAt: Date?

    /// If the message was created by a specific `/` command, the arguments of the command are stored in this variable.
    public let arguments: String?

    /// The ID of the parent message, if the message is a reply, otherwise `nil`.
    public let parentMessageId: MessageId?

    /// Contains the number of replies for this message.
    public let replyCount: Int

    /// Quoted message.
    ///
    /// If message is inline reply this property will contain the message quoted by this reply.
    ///
    public var quotedMessage: ChatMessage? { _quotedMessage }
    @CoreDataLazy internal var _quotedMessage: ChatMessage?

    public var quotedMessageId: MessageId?

    /// The channel id of channel which this message is forwarded from.
    public var forwardChannelId: ChannelId?

    /// A flag indicating whether the message was bounced due to moderation.
    public let isBounced: Bool

    /// A flag indicating whether the message is a silent message.
    ///
    /// Silent messages are special messages that don't increase the unread messages count nor mark a channel as unread.
    ///
    public let isSilent: Bool

    /// A flag indicating whether the message is a shadowed message.
    ///
    /// Shadowed message are special messages that are sent from shadow banned users.
    ///
    public let isShadowed: Bool

    /// The reactions to the message created by any user.
    public let reactionScores: [MessageReactionType: Int]

    /// The number of reactions per reaction type.
    public let reactionCounts: [MessageReactionType: Int]

    /// The user which is the author of the message.
    ///
    /// - Important: The `author` property is loaded and evaluated lazily to maintain high performance.
    public var author: ChatUser { _author }

    @CoreDataLazy internal var _author: ChatUser

    /// A list of users that are mentioned in this message.
    ///
    /// - Important: The `mentionedUsers` property is loaded and evaluated lazily to maintain high performance.
    public var mentionedUsers: Set<ChatUser> { _mentionedUsers }

    @CoreDataLazy internal var _mentionedUsers: Set<ChatUser>

    public var mentionedAll: Bool

    public var pinnedAt: Date?

    /// A list of users that participated in this message thread.
    /// The last user in the list is the author of the most recent reply.
    public var threadParticipants: [ChatUser] { _threadParticipants }

    @CoreDataLazy internal var _threadParticipants: [ChatUser]

    public var threadParticipantsCount: Int { _threadParticipantsCount }

    @CoreDataLazy internal var _threadParticipantsCount: Int

    @CoreDataLazy internal var _attachments: [AnyMessageAttachment]

    /// The overall attachment count by attachment type.
    public var attachmentCounts: [AttachmentType: Int] {
        _attachments.reduce(into: [:]) { counts, attachment in
            counts[attachment.type] = (counts[attachment.type] ?? 0) + 1
        }
    }

    /// A list of latest 25 replies to this message.
    ///
    /// - Important: The `latestReplies` property is loaded and evaluated lazily to maintain high performance.
    public var latestReplies: [ChatMessage] { _latestReplies }
    // "Move to async"
    @CoreDataLazy internal var _latestReplies: [ChatMessage]

    /// A possible additional local state of the message. Applies only for the messages of the current user.
    ///
    /// Most of the time this value is `nil`. This value is always `nil` for messages not from the current user. A typical
    /// use of this value is to check if a message is pending send/delete, and update the UI accordingly.
    ///
    public let localState: LocalMessageState?

    /// An indicator whether the message is flagged by the current user.
    ///
    /// - Note: Please be aware that the value of this field is not persisted on the server,
    /// and is valid only locally for the current session.
    public let isFlaggedByCurrentUser: Bool

    /// The latest reactions to the message created by any user.
    ///
    /// - Note: There can be `10` reactions at max.
    /// - Important: The `latestReactions` property is loaded and evaluated lazily to maintain high performance.
    public var latestReactions: Set<MessageReaction> { _latestReactions }

    @CoreDataLazy internal var _latestReactions: Set<MessageReaction>

    /// The entire list of reactions to the message left by the current user.
    ///
    /// - Important: The `currentUserReactions` property is loaded and evaluated lazily to maintain high performance.
    public var currentUserReactions: Set<MessageReaction> { _currentUserReactions }

    @CoreDataLazy internal var _currentUserReactions: Set<MessageReaction>

    public var currentUserReactionsCount: Int { _currentUserReactionsCount }

    @CoreDataLazy internal var _currentUserReactionsCount: Int

    /// `true` if the author of the message is the currently logged-in user.
    public let isSentByCurrentUser: Bool

    /// The available automatic translations for this message.
    public let translations: [TranslationLanguage: String]?

    /// Gets the translated text given the desired language in case the translation is valid.
    public func translatedText(for language: TranslationLanguage) -> String? {
        guard let translatedText = translations?[language] else { return nil }
        guard translatedText != text else { return nil }
        guard language != originalLanguage else { return nil }
        guard !text.isEmpty else { return nil }
        guard command == nil else { return nil }
        return translatedText
    }

    /// The original language of the message.
    public let originalLanguage: TranslationLanguage?
    /// The moderation details in case the message was moderated.
    public let moderationDetails: MessageModerationDetails?

    /// If the message is authored by the current user this field contains the list of channel members
    /// who read this message (excluding the current user).
    ///
    /// - Note: For the message authored by other members this field is always empty.
    /// - Important: The `readBy` loads and evaluates user models. If you're interested only in `count`,
    /// it's recommended to use `readByCount` instead of `readBy.count` for better performance.
    public var readBy: Set<ChatUser> { _readBy }

    @CoreDataLazy internal var _readBy: Set<ChatUser>

    /// For the message authored by the current user this field contains number of channel members
    /// who has read this message (excluding the current user).
    ///
    /// - Note: For the message authored by other channel members this field always returns `0`.
    public var readByCount: Int { _readByCount }

    @CoreDataLazy internal var _readByCount: Int

    internal init(
        id: MessageId,
        cid: ChannelId,
        text: String,
        oldTexts: [MessageEditHistory]?,
        type: MessageType,
        command: String?,
        createdAt: Date,
        locallyCreatedAt: Date?,
        updatedAt: Date,
        deletedAt: Date?,
        arguments: String?,
        parentMessageId: MessageId?,
        replyCount: Int,
        quotedMessageId: MessageId?,
        quotedMessage: @escaping () -> ChatMessage?,
        forwardChannelId: ChannelId?,
        isBounced: Bool,
        isSilent: Bool,
        isShadowed: Bool,
        reactionScores: [MessageReactionType: Int],
        reactionCounts: [MessageReactionType: Int],
        author: @escaping () -> ChatUser,
        mentionedUsers: @escaping () -> Set<ChatUser>,
        mentionedAll: Bool,
        threadParticipants: @escaping () -> [ChatUser],
        threadParticipantsCount: @escaping () -> Int,
        attachments: @escaping () -> [AnyMessageAttachment],
        latestReplies: @escaping () -> [ChatMessage],
        localState: LocalMessageState?,
        isFlaggedByCurrentUser: Bool,
        latestReactions: @escaping () -> Set<MessageReaction>,
        currentUserReactions: @escaping () -> Set<MessageReaction>,
        currentUserReactionsCount: @escaping () -> Int,
        isSentByCurrentUser: Bool,
        translations: [TranslationLanguage: String]?,
        originalLanguage: TranslationLanguage?,
        moderationDetails: MessageModerationDetails?,
        readBy: @escaping () -> Set<ChatUser>,
        readByCount: @escaping () -> Int,
        underlyingContext: NSManagedObjectContext?,
        textUpdatedAt: Date?
    ) {
        self.id = id
        self.cid = cid
        self.text = text
        self.type = type
        self.oldTexts = oldTexts
        self.command = command
        self.createdAt = createdAt
        self.locallyCreatedAt = locallyCreatedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.arguments = arguments
        self.parentMessageId = parentMessageId
        self.replyCount = replyCount
        self.quotedMessageId = quotedMessageId
        self.forwardChannelId = forwardChannelId
        self.isBounced = isBounced
        self.isSilent = isSilent
        self.isShadowed = isShadowed
        self.reactionScores = reactionScores
        self.reactionCounts = reactionCounts
        self.localState = localState
        self.isFlaggedByCurrentUser = isFlaggedByCurrentUser
        self.isSentByCurrentUser = isSentByCurrentUser
        self.translations = translations
        self.originalLanguage = originalLanguage
        self.moderationDetails = moderationDetails
        self.textUpdatedAt = textUpdatedAt
        self.mentionedAll = mentionedAll

        $_author = (author, underlyingContext)
        $_mentionedUsers = (mentionedUsers, underlyingContext)
        $_threadParticipants = (threadParticipants, underlyingContext)
        $_threadParticipantsCount = (threadParticipantsCount, underlyingContext)
        $_attachments = (attachments, underlyingContext)
        $_latestReplies = (latestReplies, underlyingContext)
        $_latestReactions = (latestReactions, underlyingContext)
        $_currentUserReactions = (currentUserReactions, underlyingContext)
        $_currentUserReactionsCount = (currentUserReactionsCount, underlyingContext)
        $_quotedMessage = (quotedMessage, underlyingContext)
        $_readBy = (readBy, underlyingContext)
        $_readByCount = (readByCount, underlyingContext)
    }
}

public extension ChatMessage {
    /// Text content after change mention user's Id by mention user's name
    public var textContentAfterParseMention: String? {
        guard !mentionedUsers.isEmpty else {
            return nil
        }
        var text = self.text
        for mentionedUser in self.mentionedUsers {
            text = text.replacingOccurrences(of: mentionedUser.mentionString, with: mentionedUser.mentionsDisplayString)
        }
        return text
    }
    /// The total number of reactions.
    var totalReactionsCount: Int {
        reactionCounts.values.reduce(0, +)
    }

    /// Returns all the attachments with the payload type-erased.
    var allAttachments: [AnyMessageAttachment] {
        _attachments
    }

    /// Returns all the attachments with the payload of the provided type.
    ///
    /// - Important: Attachments are loaded lazily and cached to maintain high performance.
    func attachments<Payload: AttachmentPayload>(
        payloadType: Payload.Type
    ) -> [MessageAttachment<Payload>] {
        _attachments.compactMap {
            $0.attachment(payloadType: payloadType)
        }
    }

    /// Returns the attachments of `.image` type.
    ///
    /// - Important: The `imageAttachments` are loaded lazily and cached to maintain high performance.
    var imageAttachments: [MessageImageAttachment] {
        attachments(payloadType: ImageAttachmentPayload.self)
    }

    /// Returns the attachments of `.file` type.
    ///
    /// - Important: The `fileAttachments` are loaded lazily and cached to maintain high performance.
    var fileAttachments: [MessageFileAttachment] {
        attachments(payloadType: FileAttachmentPayload.self)
    }

    /// Returns the attachments of `.video` type.
    ///
    /// - Important: The `videoAttachments` are loaded lazily and cached to maintain high performance.
    var videoAttachments: [MessageVideoAttachment] {
        attachments(payloadType: VideoAttachmentPayload.self)
    }

    /// Returns the attachments of `.linkPreview` type.
    ///
    /// - Important: The `linkAttachments` are loaded lazily and cached to maintain high performance.
    var linkAttachments: [MessageLinkAttachment] {
        attachments(payloadType: LinkAttachmentPayload.self)
    }

    /// Returns the attachments of `.audio` type.
    ///
    /// - Important: The `audioAttachments` are loaded lazily and cached to maintain high performance.
    var audioAttachments: [MessageAudioAttachment] {
        attachments(payloadType: AudioAttachmentPayload.self)
    }

    /// Returns the attachments of `.voiceRecording` type.
    ///
    /// - Important: The `voiceRecordingAttachments` are loaded lazily and cached to maintain high performance.
    var voiceRecordingAttachments: [MessageVoiceRecordingAttachment] {
        attachments(payloadType: VoiceRecordingAttachmentPayload.self)
    }

    /// Returns attachment for the given identifier.
    /// - Parameter id: Attachment identifier.
    /// - Returns: A type-erased attachment.
    func attachment(with id: AttachmentId) -> AnyMessageAttachment? {
        _attachments.first { $0.id == id }
    }

    var signalMessage: SignalMessage? {
        guard type == .signal else {
            return nil
        }

        return SignalMessage(signalMessage: text)
    }

    /// The message delivery status.
    /// Always returns `nil` when the message is authored by another user.
    /// Always returns `nil` when the message is `system/error/ephemeral/deleted`.
    var deliveryStatus: MessageDeliveryStatus? {
        guard isSentByCurrentUser else {
            // Delivery status exists only for messages sent by the current user.
            return nil
        }

        guard type == .regular || type == .reply else {
            // Delivery status only makes sense for regular messages and thread replies.
            return nil
        }

        switch localState {
        case .pendingSend, .sending, .pendingSync, .syncing, .deleting:
            return .pending
        case .sendingFailed, .syncingFailed, .deletingFailed:
            return .failed
        case nil:
            return readByCount > 0 ? .read : .sent
        }
    }

    var isLocalOnly: Bool {
        if let localState = self.localState {
            return localState.isLocalOnly
        }
        
        return type == .ephemeral || type == .error
    }
}

extension ChatMessage: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A type of the message.
public enum MessageType: String, Codable {
    /// A regular message created in the channel.
    case regular

    /// A temporary message which is only delivered to one user. It is not stored in the channel history. Ephemeral messages
    /// are normally used by commands to prompt messages or request for actions.
    case ephemeral

    /// An error message generated as a result of a failed command. It is also ephemeral, as it is not stored in the channel
    /// history and is only delivered to one user.
    case error

    /// The message is a reply to another message. Use the `parentMessageId` variable of the message to get the parent
    /// message data.
    case reply

    /// The message is a call.
    case signal

    /// A message generated by a system event, like updating the channel or muting a user.
    case system

    /// A sticker message.
    case sticker

    /// A deleted message.
    case deleted
}

/// A possible additional local state of the message. Applies only for the messages of the current user.
public enum LocalMessageState: String {
    /// The message is waiting to be synced.
    case pendingSync
    /// The message is currently being synced
    case syncing
    /// Syncing of the message failed after multiple of tries. The system is not trying to sync this message anymore.
    case syncingFailed

    /// The message is waiting to be sent.
    case pendingSend
    /// The message is currently being sent to the servers.
    case sending
    /// Sending of the message failed after multiple of tries. The system is not trying to send this message anymore.
    case sendingFailed

    /// The message is waiting to be deleted.
    case deleting
    /// Deleting of the message failed after multiple of tries. The system is not trying to delete this message anymore.
    case deletingFailed

    /// If the message is available only locally. The message is not on the server.
    var isLocalOnly: Bool {
        self == .pendingSend || self == .sendingFailed || self == .sending
    }
}

public enum LocalReactionState: String {
    ///  The reaction state is unknown
    case unknown = ""

    /// The reaction is waiting to be sent to the server
    case pendingSend

    /// The reaction is being sent
    case sending

    /// Creating the reaction failed and cannot be fulfilled
    case sendingFailed

    /// The reaction is waiting to be deleted from the server
    case pendingDelete

    /// The reaction is being deleted
    case deleting

    /// Deleting of the reaction failed and cannot be fulfilled
    case deletingFailed
}

/// The type describing message delivery status.
public struct MessageDeliveryStatus: RawRepresentable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The message delivery state for message that is being sent/edited/deleted.
    public static let pending = Self(rawValue: "pending")

    /// The message delivery state for message that is successfully sent.
    public static let sent = Self(rawValue: "sent")

    /// The message delivery state for message that is successfully sent and read by at least one channel member.
    public static let read = Self(rawValue: "read")

    /// The message delivery state for message failed to be sent/edited/deleted.
    public static let failed = Self(rawValue: "failed")
}
/// The type represent System Messages
public enum SystemMessage {
    case channelNameUpdated(userId: String, channelName: String)
    case channelImageUpdated(userId: String)
    case channelDescriptionUpdated(userId: String)
    case memberRemoved(userId: String)
    case memberBanned(userId: String)
    case memberUnbanned(userId: String)
    case memberPromoted(userId: String)
    case memberDemoted(userId: String)
    case memberCapabilitiesUpdated(userId: String)
    case inviteAccepted(userId: String)
    case inviteRejected(userId: String)
    case leaveChannel(userId: String)
    case truncateMessages(userId: String)
    case channelPublicUpdated(userId: String, isPublic: Bool)
    case memberMessageCoolDown(userId: String, duration: Int)
    case channelFilterKeywordsUpdated(userId: String)
    case memberJoined(userId: String)
    case ownerPromoted(oldId: String, newId: String)
    case messagePinned(userId: String, messageId: String)
    case messageUnpinned(userId: String, messageId: String)

    case unknown(systemMessage: String)

    public
    init(systemMessage: String) {
        let components = systemMessage.split(separator: " ")
        guard components.count > 1 else {
            self = .unknown(systemMessage: systemMessage)
            return
        }
        let idString = String(components[0])
        let userId = String(components[1])
        let id = Int(idString)
        switch id {
        case 1:
            guard components.count > 2 else {
                self = .channelNameUpdated(userId: userId, channelName: "")
                return
            }
            let updatedChannelName = components[2...].joined(separator: " ")
            self = .channelNameUpdated(userId: userId, channelName: updatedChannelName)
        case 2:
            self = .channelImageUpdated(userId: userId)
        case 3:
            self = .channelDescriptionUpdated(userId: userId)
        case 4:
            self = .memberRemoved(userId: userId)
        case 5:
            self = .memberBanned(userId: userId)
        case 6:
            self = .memberUnbanned(userId: userId)
        case 7:
            self = .memberPromoted(userId: userId)
        case 8:
            self = .memberDemoted(userId: userId)
        case 9:
            self = .memberCapabilitiesUpdated(userId: userId)
        case 10:
            self = .inviteAccepted(userId: userId)
        case 11:
            self = .inviteRejected(userId: userId)
        case 12:
            self = .leaveChannel(userId: userId)
        case 13:
            self = .truncateMessages(userId: userId)
        case 14:
            guard components.count > 2, let isPublic = components[2] == "true" ? true : false else {
                self = .unknown(systemMessage: systemMessage)
                return
            }
            self = .channelPublicUpdated(userId: userId, isPublic: isPublic)
        case 15:
            guard components.count > 2, let duration = Int(components[2]) else {
                self = .unknown(systemMessage: systemMessage)
                return
            }
            self = .memberMessageCoolDown(userId: userId, duration: duration / 1000)
        case 16:
            self = .channelFilterKeywordsUpdated(userId: userId)
        case 17:
            self = .memberJoined(userId: userId)
        case 18:
            guard components.count > 2, let newId = components[2] as? Substring else {
                self = .unknown(systemMessage: systemMessage)
                return
            }
            self = .ownerPromoted(oldId: userId, newId: String(newId))
        case 19:
            guard components.count > 2,
                  let messageId = components[2] as? Substring else {
                self = .unknown(systemMessage: systemMessage)
                return
            }
            self = .messagePinned(userId: userId, messageId: String(messageId))
        case 20:
            guard components.count > 2,
                                  let messageId = components[2] as? Substring else {
                self = .unknown(systemMessage: systemMessage)
                return
            }
            self = .messageUnpinned(userId: userId, messageId: String(messageId))
        default:
            self = .unknown(systemMessage: systemMessage)
        }
    }
}

public enum SignalMessage {
    case audioCallStart(userId: String)
    case audioCallMissed(userId: String)
    case audioCallEnded(userId: String, ender: String, duration: Int)
    case audioCallRejected(userId: String)
    case videoCallStart(userId: String)
    case videoCallMissed(userId: String)
    case videoCallEnded(userId: String, ender: String, duration: Int)
    case videoCallRejected(userId: String)
    case audioCallBusy(userId: String)
    case videoCallBusy(userId: String)

    case unknown(signalMessage: String)

    public init(signalMessage: String) {
        let components = signalMessage.split(separator: " ")
        guard components.count > 1 else {
            self = .unknown(signalMessage: signalMessage)
            return
        }
        guard let id = Int(components[0]) else {
            self = .unknown(signalMessage: signalMessage)
            return
        }
        let userId = String(components[1])

        switch id {
        case 1:
            self = .audioCallStart(userId: userId)
        case 2:
            self = .audioCallMissed(userId: userId)
        case 3:
            guard components.count > 3,
                  let duration = Int(components[3]) else {
                self = .unknown(signalMessage: signalMessage)
                return
            }
            let enderId = String(components[2])
            self = .audioCallEnded(userId: userId, ender: enderId, duration: duration)
        case 4:
            self = .videoCallStart(userId: userId)
        case 5:
            self = .videoCallMissed(userId: userId)
        case 6:
            guard components.count > 3,
                  let duration = Int(components[3]) else {
                self = .unknown(signalMessage: signalMessage)
                return
            }
            let enderId = String(components[2])
            self = .videoCallEnded(userId: userId, ender: enderId, duration: duration)
        case 7:
            self = .audioCallRejected(userId: userId)
        case 8:
            self = .videoCallRejected(userId: userId)
        case 9:
            self = .audioCallBusy(userId: userId)
        case 10:
            self = .videoCallBusy(userId: userId)
        default:
            self = .unknown(signalMessage: signalMessage)
        }
    }

    public var senderId: String? {
        switch self {
        case .audioCallStart(userId: let userId):
            return userId
        case .audioCallMissed(userId: let userId):
            return userId
        case .audioCallEnded(userId: let userId, ender: let ender, duration: let duration):
            return userId
        case .audioCallRejected(userId: let userId):
            return userId
        case .videoCallStart(userId: let userId):
            return userId
        case .videoCallMissed(userId: let userId):
            return userId
        case .videoCallEnded(userId: let userId, ender: let ender, duration: let duration):
            return userId
        case .videoCallRejected(userId: let userId):
            return userId
        case .audioCallBusy(let userId):
            return userId
        case .videoCallBusy(userId: let userId):
            return userId
        case .unknown(signalMessage: let signalMessage):
            return nil
        }
    }

    public var enderId: String? {
        switch self {
        case .audioCallEnded(userId: let userId, ender: let ender, duration: _):
            return ender
        case .videoCallEnded(userId: let userId, ender: let ender, duration: _):
            return ender
        default:
            return nil
        }
    }

    public var endedReason: CallEndedReason? {
        switch self {
        case .audioCallEnded(let userId, let sender, let duration):
            return duration == 0 ? .cancelled : .normal
        case .videoCallEnded(let userId, let sender, let duration):
            return duration == 0 ? .cancelled : .normal
        case .audioCallMissed, .videoCallMissed:
            return .noAnswer
        case .audioCallRejected, .videoCallRejected:
            return .rejected
        case .audioCallBusy, .videoCallBusy:
            return .busy
        default:
            return nil
        }
    }

    public var isMissed: Bool {
        switch endedReason {
        case .cancelled, .noAnswer, .rejected, .busy:
            return true
        case .normal:
            return false
        case .none:
            return false
        }
    }

    public var isVideo: Bool {
        switch self {
        case .videoCallStart, .videoCallMissed, .videoCallRejected, .videoCallEnded, .videoCallBusy:
            return true
        default:
            return false
        }
    }
}

extension SignalMessage: Decodable {
    public init(from decoder: any Decoder) throws {
        let stringValue = try decoder.singleValueContainer().decode(String.self)
        self.init(signalMessage: stringValue)
    }
}


public enum CallEndedReason: String, Decodable {
    case cancelled
    case noAnswer
    case rejected
    case busy
    case normal
}
