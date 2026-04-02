//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Coding keys channel related payloads.
public enum ChannelCodingKeys: String, CodingKey, CaseIterable {
    /// The id of the channel
    case id
    /// A combination of channel id and type.
    case cid
    /// A combination of channel id and type of the parent channel type.
    case parentcid = "parent_cid"
    /// Name for the channel.
    case name
    case cDescription = "description"
    /// Optional image URL for the channel.
    case imageURL = "image"
    /// Is channel public or not.
    case isPublic = "public"
    /// Is pinned or not.
    case isPinned = "is_pinned"
    /// Channel should save message on server or not. If true all message will save on sever
    case saveMessage = "save_message"
    /// A type.
    case typeRawValue = "type"
    /// A last message date.
    case lastMessageAt = "last_message_at"
    /// A user created by.
    case createdBy = "created_by"
    /// A created date.
    case createdAt = "created_at"
    /// A created date.
    case updatedAt = "updated_at"
    /// A deleted date.
    case deletedAt = "deleted_at"
    /// A truncated date.
    case truncatedAt = "truncated_at"
    /// Hidden flag.
    case hidden
    /// A channel config.
    case config
    /// The channel own capabilities.
    case ownCapabilities = "own_capabilities"
    /// The channel capabilities.
    case memberCapabilities = "member_capabilities"
    /// The channel filter words.
    case filterWords = "filter_words"
    /// Members.
    case members
    /// Invites.
    case invites
    /// The team the channel belongs to.
    case team
    case memberCount = "member_count"
    /// Cooldown duration for the channel, if it's in slow mode.
    /// This value will be 0 if the channel is not in slow mode.
    case cooldownDuration = "member_message_cooldown"
    case projectId = "project_id"
    ///
    case invitedAt = "invited_at"
    /// Toics enabled flag.
    case topicsEnabled = "topics_enabled"
    /// Close a topic flag.
    case isClosedTopic = "is_closed_topic"
    case mlsEnabled = "mls_enabled"
    case mlsEnabledAt = "mls_enabled_at"
    case mlsEpoch = "mls_epoch"
    case commit
    case welcome
    case epoch
    case ratchetTree = "ratchet_tree"
    case groupInfo = "group_info"
}
