//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation

/// A type representing a chat channel. `Channel` is an immutable snapshot of a channel entity at the given time.
///
public struct Channel {
    /// The `ChannelId` of the channel.
    public let cid: ChannelId
    
    /// The parent channel id if this channel is a topic.
    public let parentCid: ChannelId?

    /// Name for this channel.
    public let name: String?

    public let cDescription: String?

    /// Image (avatar) url for this channel.
    public let imageURL: URL?

    /// Determine message will be saved on sever or not.
    public let saveMessage: Bool?

    /// The date of the last message in the channel.
    public let lastMessageAt: Date?

    /// The default sorting at date.
    public let defaultSortingAt: Date?

    /// The date when the channel was created.
    public let createdAt: Date

    /// The date when the channel was updated.
    public let updatedAt: Date

    /// If the channel was deleted, this field contains the date of the deletion.
    public let deletedAt: Date?

    /// If the channel was truncated, this field contains the date of the truncation.
    public let truncatedAt: Date?

    /// Flag for representing hidden state for the channel.
    public let isHidden: Bool

    /// Determine channel is public or private.
    public let isPublic: Bool

    /// Determine channel is pinned or not.
    public let isPinned: Bool

    /// The user which created the channel.
    public let createdBy: ChatUser?

    /// A configuration struct of the channel. It contains additional information about the channel settings.
    public let config: ChannelConfig?

    /// The list of actions that the current user can perform in a channel.
    public let ownCapabilities: Set<ChannelCapability>
    /// The list of actions that all channel member can perform in a channel.
    public let memberCapabilities: Set<ChannelCapability>
    /// The list of filter words that channel will prevent sending this words.
    public let filterWords: Set<String>

    /// The total number of members in the channel.
    public let memberCount: Int
    
    public let topicsEnabled: Bool
    
    public let isClosedTopic: Bool

    /// A list of members of this channel.
    ///
    /// Array is sorted and the most recently active members will be first.
    ///
    /// - Important: This list doesn't have to contain all members of the channel. To access the full list of members, create
    /// a `ChannelMemberListController` for this channel and use it to query all channel members.
    ///
    /// - Note: This property will contain no more than `ErmisClientConfig.channel.lastActiveMembersLimit` members.
    ///
    public var lastActiveMembers: [ChannelMember] { _lastActiveMembers }
    @CoreDataLazy private var _lastActiveMembers: [ChannelMember]

    /// A list of currently typing users.
    public var currentlyTypingUsers: Set<ChatUser> { _currentlyTypingUsers }
    @CoreDataLazy private var _currentlyTypingUsers: Set<ChatUser>

    /// If the current user is a member of the channel, this variable contains the details about the membership.
    public let membership: ChannelMember?

    /// A list of users and/or channel members currently actively watching the channel.
    ///
    /// Array is sorted and the most recently active watchers will be first.
    ///
    /// - Important: This list doesn't have to contain all watchers of the channel. To access the full list of watchers, create
    /// a `ChannelWatcherListController` for this channel and use it to query all channel watchers.
    ///
    /// - Note: This property will contain no more than `ErmisClientConfig.channel.lastActiveWatchersLimit` members.
    ///
    public var lastActiveWatchers: [ChatUser] { _lastActiveWatchers }
    @CoreDataLazy private var _lastActiveWatchers: [ChatUser]

    /// The total number of online members watching this channel.
    public let watcherCount: Int

    /// The team the channel belongs to.
    ///
    /// You need to enable multi-tenancy if you want to use this otherwise it is always nil
    ///
    public let team: TeamId?

    /// The unread counts for the channel.
    public var unreadCount: ChannelUnreadCount { _unreadCount }
    @CoreDataLazy private var _unreadCount: ChannelUnreadCount

    /// An option to enable ban users.
//    public let banEnabling: BanEnabling

    /// Latest messages present on the channel. The first item of the array, is the most recent message.
    ///
    /// This field contains only the latest messages of the channel. You can get all existing messages in the channel by creating
    /// and using a `ChannelController` for this channel id.
    ///
    /// The amount of latest messages is controlled by the `ErmisClientConfig.LocalCaching.latestMessagesLimit`.
    ///
    /// - Important: The `latestMessages` property is loaded and evaluated lazily to maintain high performance.
    public var latestMessages: [ChatMessage] { _latestMessages }
    // "Move to async"
    @CoreDataLazy private var _latestMessages: [ChatMessage]

    /// Latest message present on the channel sent by current user even if sent on a thread.
    ///
    /// - Important: The `lastMessageFromCurrentUser` property is loaded and evaluated lazily to maintain high performance.
    public var lastMessageFromCurrentUser: ChatMessage? { _lastMessageFromCurrentUser }
    @CoreDataLazy private var _lastMessageFromCurrentUser: ChatMessage?

    /// Pinned messages present on the channel.
    ///
    /// This field contains only the pinned messages of the channel. You can get all existing messages in the channel by creating
    /// and using a `ChannelController` for this channel id.
    ///
    /// - Important: The `pinnedMessages` property is loaded and evaluated lazily to maintain high performance.
    public var pinnedMessages: [ChatMessage] { _pinnedMessages }
    // "Move to async"
    @CoreDataLazy private var _pinnedMessages: [ChatMessage]

    /// Read states of the users for this channel.
    ///
    /// You can use this information to show to your users information about what messages were read by certain users.
    ///
    public let reads: [ChannelRead]

    /// Says whether the channel is muted by the current user.
    ///
    /// - Important: The `isMuted` property is loaded and evaluated lazily to maintain high performance.
    public var isMuted: Bool { membership?.notificationEnable == false }

    @CoreDataLazy private var _muteDetails: MuteDetails?

    /// Cooldown duration for the channel, if it's in slow mode.
    /// This value will be 0 if the channel is not in slow mode.
    /// This value is in seconds.
    public let cooldownDuration: Int

    /// The channel message is supposed to be shown in channel preview.
    ///
    /// - Important: The `previewMessage` can differ from `latestMessages.first` (or even not be included into `latestMessages`)
    /// because the preview message is the last `non-deleted` message sent to the channel.
    public var previewMessage: ChatMessage? { _previewMessage }
    // "Move to async?"
    @CoreDataLazy private var _previewMessage: ChatMessage?

    /// The parent channel of topic.
    public var parent: Channel? { _parent }
    @CoreDataLazy private var _parent: Channel?

    /// The topic channels of current channel.
    public var topics: [Channel]? { _topics }
    
    public var mlsEnabled: Bool
    public var mlsEnabledAt: Date?
    public var mlsEpoch: Int

    // "Move to async?"
    @CoreDataLazy private var _topics: [Channel]?

    public var composerUnsentContent: ComposerContent?

    public var canDeleteChannel: Bool {
        return membership?.memberRole == .owner
    }

    public var canUpdateChannelMembers: Bool {
        return membership?.memberRole == .owner || membership?.memberRole == .admin || membership?.memberRole == .moderator
    }
    // MARK: - Internal

    var hasUnread: Bool {
        topicsUnreadCount.messages > 0
    }

    /// A helper variable to cache the result of the filter for only banned members.
    //  lazy var bannedMembers: Set<ChannelMember> = Set(self.members.filter { $0.isBanned })

    /// A list of users to invite in the channel.
//    let invitedMembers: Set<ChannelMember> // TODO: Why is this not public?

    init(
        cid: ChannelId,
        parentCid: ChannelId? = nil,
        name: String?,
        description: String?,
        imageURL: URL?,
        saveMessage: Bool?,
        lastMessageAt: Date? = nil,
        defaultSortingAt: Date? = nil,
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        deletedAt: Date? = nil,
        truncatedAt: Date? = nil,
        isHidden: Bool,
        isPublic: Bool,
        isPinned: Bool?,
        topicEnabled: Bool = false,
        isClosedTopic: Bool = false,
        createdBy: ChatUser? = nil,
        config: ChannelConfig? = .init(),
        ownCapabilities: Set<ChannelCapability> = [],
        memberCapabilities: Set<ChannelCapability> = [],
        filterWords: Set<String> = [],
        lastActiveMembers: @escaping (() -> [ChannelMember]) = { [] },
        membership: ChannelMember? = nil,
        currentlyTypingUsers: @escaping () -> Set<ChatUser> = { [] },
        lastActiveWatchers: @escaping (() -> [ChatUser]) = { [] },
        team: TeamId? = nil,
        unreadCount: @escaping () -> ChannelUnreadCount = { .noUnread },
        watcherCount: Int = 0,
        memberCount: Int = 0,
        reads: [ChannelRead] = [],
        cooldownDuration: Int = 0,
        latestMessages: @escaping (() -> [ChatMessage]) = { [] },
        parent: @escaping(() -> Channel?) = { nil },
        topics: @escaping (() -> [Channel]?) = { nil },
        mlsEnabled: Bool = false,
        mlsEnabledAt: Date? = nil,
        mlsEpoch: Int = 0,
        lastMessageFromCurrentUser: @escaping (() -> ChatMessage?) = { nil },
        pinnedMessages: @escaping (() -> [ChatMessage]) = { [] },
        previewMessage: @escaping () -> ChatMessage?,
        underlyingContext: NSManagedObjectContext?,
        composerUnsentContent: ComposerContent? = nil
    ) {
        self.cid = cid
        self.parentCid = parentCid
        self.name = name
        self.cDescription = description
        self.imageURL = imageURL
        self.saveMessage = saveMessage
        self.lastMessageAt = lastMessageAt
        self.defaultSortingAt = defaultSortingAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.truncatedAt = truncatedAt
        self.isHidden = isHidden
        self.isPublic = isPublic
        self.isPinned = isPinned ?? false
        self.topicsEnabled = topicEnabled
        self.isClosedTopic = isClosedTopic
        self.createdBy = createdBy
        self.config = config
        self.ownCapabilities = ownCapabilities
        self.memberCapabilities = memberCapabilities
        self.filterWords = filterWords
        self.membership = membership
        self.team = team
        self.watcherCount = watcherCount
        self.memberCount = memberCount
        self.reads = reads.sorted(by: {
            if $0.lastReadAt == $1.lastReadAt {
                return $0.user.userId < $1.user.userId
            }
            return $0.lastReadAt < $1.lastReadAt
        })
        self.cooldownDuration = cooldownDuration
        self.composerUnsentContent = composerUnsentContent
        self.mlsEnabled = mlsEnabled
        self.mlsEnabledAt = mlsEnabledAt
        self.mlsEpoch = mlsEpoch
        $_unreadCount = (unreadCount, underlyingContext)
        $_latestMessages = (latestMessages, underlyingContext)
        $_lastMessageFromCurrentUser = (lastMessageFromCurrentUser, underlyingContext)
        $_lastActiveMembers = (lastActiveMembers, underlyingContext)
        $_currentlyTypingUsers = (currentlyTypingUsers, underlyingContext)
        $_lastActiveWatchers = (lastActiveWatchers, underlyingContext)
        $_pinnedMessages = (pinnedMessages, underlyingContext)
        $_previewMessage = (previewMessage, underlyingContext)
        $_parent = (parent, underlyingContext)
        $_topics = (topics, underlyingContext)
    }
}

extension Channel {
    /// The type of the channel.
    public var type: ChannelType { cid.type }

    /// Returns `true` if the channel was deleted.
    public var isDeleted: Bool { deletedAt != nil }

    /// Checks if read events evadable for the current user.
//    public var readEventsEnabled: Bool { /* config.readEventsEnabled && members.contains(Member.current) */ fatalError() }

    /// Returns `true` when the channel is a direct-message channel.
    /// A "direct message" channel is created when client sends only the user id's for the channel and not an explicit `cid`,
    /// so backend creates a `cid` based on member's `id`s
    public var isDirectMessageChannel: Bool {
//        cid.id.hasPrefix("!members")
        cid.type == .messaging
    }

    /// Returns direct user role when channel is direct-message channel.
    public var directUserMembership: ChannelMember? {
        guard isDirectMessageChannel else {
            return nil
        }
        return lastActiveMembers.filter({ $0.id != membership?.id}).first
    }

    /// Returns `true` if the channel has one or more unread messages for the current user.
    public var isUnread: Bool { topicsUnreadCount != .noUnread }

    /// The combined unread count of all topics (also contain parent channel unread)
    public var topicsUnreadCount: ChannelUnreadCount {
        guard let topics else {
            return unreadCount
        }

        let topicUnreadMessages = topics.reduce(0) { partialResult, channel in
            return partialResult + channel.unreadCount.messages
        }
        return ChannelUnreadCount(messages: topicUnreadMessages)
    }

    /// Return lastest preview message in parent channel and topic.
    public var topicsPreviewMessage: ChatMessage? {
        guard let topics = topics, !topics.isEmpty else {
            return self.previewMessage
        }
        var lastestPreviewMessage = self.previewMessage
        for topic in topics.filter({ $0.previewMessage != nil }) {
            guard lastestPreviewMessage != nil else {
                lastestPreviewMessage = topic.previewMessage
                continue
            }
            if topic.previewMessage!.createdAt > lastestPreviewMessage!.createdAt {
                lastestPreviewMessage = topic.previewMessage
            }
        }
        return lastestPreviewMessage
    }

    /// Returns `true` if the channel is blocked
    public var isBlocked: Bool {
        return membership?.isBlockedFromChannel ?? false
    }
    /// Returns `true` if current user is guest (open channel with public link, and not join channel yet)
    public var isGuess: Bool {
        return isPublic && membership == nil
    }
}

/// A type-erased version of `ChannelModel<CustomData>`. Not intended to be used directly.
public protocol AnyChannel {}
extension Channel: AnyChannel {}

extension Channel: Hashable {
    public static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.cid == rhs.cid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(cid)
    }
}

/// A struct describing unread counts for a channel.
public struct ChannelUnreadCount: Decodable, Equatable {
    /// The default value representing no unread messages.
    public static let noUnread = ChannelUnreadCount(messages: 0)

    /// The total number of unread messages in the channel.
    public let messages: Int
}

/// An action that can be performed in a channel.
public struct ChannelCapability: RawRepresentable, ExpressibleByStringLiteral, Hashable {
    public var rawValue: String

    public init?(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// Ability to delete own messages from the channel.
    public static var deleteOwnMessage: Self = "delete-own-message"
    /// Ability to quote a message.
    public static var quoteMessage: Self = "quote-message"
    /// Ability to use message search.
    public static var searchMessages: Self = "search-messages"
    /// Ability to send a message.
    public static var sendMessage: Self = "send-message"
    /// Ability to send reactions.
    public static var sendReaction: Self = "send-reaction"
    /// Ability to thread reply to a message.
    public static var sendReply: Self = "send-reply"
    /// Ability to send and receive typing events.
    public static var sendTypingEvents: Self = "send-typing-events"
    /// Ability to update own messages in the channel.
    public static var updateOwnMessage: Self = "update-own-message"
    /// Ability to upload message attachments.
    public static var uploadFile: Self = "upload-file"
    /// Ability to send and receive typing events.
    public static var typingEvents: Self = "typing-events"
    /// Ability to join a call.
    public static var joinCall: Self = "join-call"
    /// Ability to create a call.
    public static var createCall: Self = "create-call"
    /// Ability to send link.
    public static var sendLinks: Self = "send-links"
    /// Ability to pin message.
    public static var pinMessage: Self = "pin-message"
}

public extension Channel {
    
    var isAdminInTopic: Bool {
        membership?.memberRole == .owner
    }
    /// Can the current user delete own messages from the channel.
    var canDeleteOwnMessage: Bool {
        (membership != nil && memberCapabilities.contains(.deleteOwnMessage)) || membership?.memberRole != .member
    }

    /// Can the current user quote a message in this channel.
    var canQuoteMessage: Bool {
        membership != nil && memberCapabilities.contains(.quoteMessage)
    }

    /// Can the current user use message search in this channel.
    var canSearchMessages: Bool {
        membership != nil && memberCapabilities.contains(.searchMessages)
    }

    /// Can the current user send a message in this channel.
    var canSendMessage: Bool {
        (membership != nil && memberCapabilities.contains(.sendMessage)) || membership?.memberRole != .member
    }

    /// Can the current user send reactions in this channel.
    var canSendReaction: Bool {
        (membership != nil && memberCapabilities.contains(.sendReaction)) || membership?.isModerator == true
    }

    /// Can the current user thread reply to a message in this channel.
    var canSendReply: Bool {
        membership != nil && memberCapabilities.contains(.sendReply)
    }

    /// Can the current user send and receive typing events in this channel.
    var canSendTypingEvents: Bool {
        membership != nil && memberCapabilities.contains(.sendTypingEvents)
    }

    /// Can the current user update own messages in this channel.
    var canUpdateOwnMessage: Bool {
        (membership != nil && memberCapabilities.contains(.updateOwnMessage)) || membership?.isModerator == true
    }

    /// Can the current user upload message attachments in this channel.
    var canUploadFile: Bool {
        membership != nil && memberCapabilities.contains(.uploadFile)
    }

    /// Can the current user join a call in this channel.
    var canJoinCall: Bool {
        membership != nil && memberCapabilities.contains(.joinCall)
    }

    /// Can the current user create a call in this channel.
    var canCreateCall: Bool {
        membership != nil && memberCapabilities.contains(.createCall)
    }

    /// Can text message containt link.
    var canSendLink: Bool {
        (membership != nil && memberCapabilities.contains(.sendLinks)) || membership?.isModerator == true
    }

    /// Can pin the message in this channel.
    var canPinMessage: Bool {
        membership != nil && memberCapabilities.contains(.pinMessage)
    }

    /// Whether this channel resolves to an MLS group. Topics inherit the parent channel flag.
    public var isE2eeEnabled: Bool {
        mlsEnabled || (parentCid != nil && parent?.mlsEnabled == true)
    }
}
