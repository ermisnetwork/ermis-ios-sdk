//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A namespace for the `FilterKey`s suitable to be used for `ChannelListQuery`. This scope is not aware of any extra data types.
public protocol AnyChannelListFilterScope {}

/// An extra-data-specific namespace for the `FilterKey`s suitable to be used for `ChannelListQuery`.
public struct ChannelListFilterScope: FilterScope, AnyChannelListFilterScope {}

public extension Filter where Scope: AnyChannelListFilterScope {
    /// Filter to match channels containing members with specified user ids.
    static func containMembers(userIds: [UserId], projectId: String) -> Filter<Scope> {
        .in(.members, values: userIds.map{ .init(userId: $0, projectId: projectId) })
    }

    /// Filter to match channels containing at least one message.
    static var nonEmpty: Filter<Scope> {
       .greater(.lastMessageAt, than: Date(timeIntervalSince1970: 0))
    }

    /// Filter to match channels that are not related to any team.
    static var noTeam: Filter<Scope> {
        .equal(.team, to: nil)
    }

    static func directChannels(memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "member"]),
            .in(.channelType, values: ["messaging"]),
            .equal(.isBlocked, to: false),
            .equal(.projectId, to: projectId)
        ])
    }

    static func blockedChannels(memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "member"]),
            .in(.channelType, values: ["messaging"]),
            .equal(.isBlocked, to: true),
            .equal(.projectId, to: projectId)
        ])
    }

    static func searchDirectChannels(searchText: String, memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .autocomplete(.name, text: searchText),
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "member"]),
            .in(.channelType, values: ["messaging"]),
            .equal(.projectId, to: projectId)
        ])
    }

    /// Filter to match invited channels.
    static func invitedChannels(memberId: String,
                                projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["pending"]),
            .in(.channelType, values: ["messaging", "team"]),
            .equal(.projectId, to: projectId)
        ])
    }
    /// Filter to match joined channels.
    static func joinedChannels(memberId: String,
                               projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "moder", "member"]),
            .in(.channelType, values: ["messaging", "team"]),
            .equal(.projectId, to: projectId)
        ])
    }

    static func teamChannel(memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "moder", "member"]),
            .in(.channelType, values: ["team"]),
            .equal(.projectId, to: projectId)
        ])
    }

    static func unreadChannels(memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "moder", "member"]),
            .in(.channelType, values: ["messaging", "team"]),
            .contains(.unread, value: memberId+projectId),
            .equal(.projectId, to: projectId)
        ])
    }

    /// Filter to match all channels, include invited, joined, meetings channels.
    static func allChannels(memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "member", "pending", "moder"]),
            .equal(.projectId, to: projectId)
        ])
    }

    static func publicChannel(projectId: String) -> Filter<Scope> {
        .and([
            .equal(.isPublic, to: true),
            .equal(.projectId, to: projectId)
        ])
    }

    // Filter project has unread messages.
    static func unreadProjects(memberId: String, projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "member"]),
        ])
    }

    // Filter pinned channel.
    static func pinnedChannel(memberId: String,
                              projectId: String) -> Filter<Scope> {
        .and([
            .in(.members, values: [.init(userId: memberId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "moder", "member"]),
            .in(.channelType, values: ["messaging", "team"]),
            .equal(.isPinned, to: true),
            .equal(.projectId, to: projectId)
        ])
    }
}

extension Filter where Scope: AnyChannelListFilterScope {
    /// Computed var helping us determine the value of `hidden` filter.
    var hiddenFilterValue: Bool? {
        if `operator`.isGroupOperator {
            let filters = value as? [Filter] ?? []
            return filters.compactMap(\.hiddenFilterValue).first
        } else if `operator` == FilterOperator.equal.rawValue {
            return key == FilterKey<Scope, Bool>.hidden.rawValue ? (value as? Bool) : nil
        } else {
            return nil
        }
    }
}

// We don't want to expose `members` publicly because it can't be used with any other operator
// than `$in`. We expose it publicly via the `containMembers` filter helper.
extension FilterKey where Scope: AnyChannelListFilterScope {
    static var members: FilterKey<Scope, UserFilterValue> {
        .init(rawValue: "members",
              keyPathString: #keyPath(ChannelDTO.members.user.id), valueMapper: { channelMemberFilterValue in
            return channelMemberFilterValue.userId + channelMemberFilterValue.projectId
        })
    }

    static var channelType: FilterKey<Scope, String> {
        .init(rawValue: "type", keyPathString: #keyPath(ChannelDTO.typeRawValue))
    }

    static var isBlocked: FilterKey<Scope, Bool> {
        .init(rawValue: "blocked", keyPathString: #keyPath(ChannelDTO.membership.isBlocked))
    }

    static var isPublic: FilterKey<Scope, Bool> {
        .init(rawValue: "public", keyPathString: #keyPath(ChannelDTO.isPublic))
    }

    static var isPinned: FilterKey<Scope, Bool> {
        .init(rawValue: "isPinned", keyPathString: #keyPath(ChannelDTO.isPinned))
    }
}

/// Filter values to be used with `.invite` FilterKey.
public enum InviteFilterValue: String, FilterValue {
    case pending
    case accepted
    case rejected
}

/// Filter keys for channel list.
public extension FilterKey where Scope: AnyChannelListFilterScope {
    /// A filter key for matching the `cid` value.
    /// Supported operators: `in`, `equal`
    static var cid: FilterKey<Scope, ChannelId> { .init(rawValue: "cid", keyPathString: #keyPath(ChannelDTO.cid), valueMapper: { $0.rawValue }) }

    /// A filter key for matching the `id` value.
    /// Supported operators: `in`, `equal`
    /// - Warning: Querying by the channel Identifier should be done using the `cid` field as much as possible to optimize API performance.
    /// As the full channel ID, `cid`s are indexed everywhere in Ermis database where `id` is not.
    static var id: FilterKey<Scope, String> { .init(rawValue: "id", keyPathString: #keyPath(ChannelDTO.cid)) }

    /// A filter key for matching the `name` value.
    static var name: FilterKey<Scope, String> {
        .init(rawValue: "name",
              keyPathString: #keyPath(ChannelDTO.name))
    }

    /// A filter key for matching the `image` value.
    static var imageURL: FilterKey<Scope, URL> { .init(rawValue: "image", keyPathString: #keyPath(ChannelDTO.imageURL)) }

    /// A filter key for matching the `type` value.
    /// Supported operators: `in`, `equal`
    static var type: FilterKey<Scope, ChannelType> { .init(rawValue: "type", keyPathString: #keyPath(ChannelDTO.typeRawValue), valueMapper: { $0.rawValue }) }

    /// A filter key for matching the `lastMessageAt` value.
    /// Supported operators: `equal`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `notEqual`
    static var lastMessageAt: FilterKey<Scope, Date> { .init(rawValue: "last_message_at", keyPathString: #keyPath(ChannelDTO.lastMessageAt)) }

    /// A filter key for matching the `createdBy` value.
    /// Supported operators: `equal`
    static var createdBy: FilterKey<Scope, UserId> { .init(rawValue: "created_by_id", keyPathString: #keyPath(ChannelDTO.createdBy.id)) }
    /// A filter key for matching the `createdAt` value.
    /// Supported operators: `equal`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `notEqual`
    static var createdAt: FilterKey<Scope, Date> { .init(rawValue: "created_at", keyPathString: #keyPath(ChannelDTO.createdAt)) }

    /// A filter key for matching the `updatedAt` value.
    /// Supported operators: `equal`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `notEqual`
    static var updatedAt: FilterKey<Scope, Date> { .init(rawValue: "updated_at", keyPathString: #keyPath(ChannelDTO.updatedAt)) }

    /// A filter key for matching the `deletedAt` value.
    /// Supported operators: `equal`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `notEqual`
    static var deletedAt: FilterKey<Scope, Date> { .init(rawValue: "deleted_at", keyPathString: #keyPath(ChannelDTO.deletedAt)) }

    /// A filter key for querying hidden channels.
    /// Supported operators: `equal`
    // TODO: should it be using the ChannelPayload.isHidden or ChannelPayload.channel.isHidden
    static var hidden: FilterKey<Scope, Bool> { .init(rawValue: "hidden", keyPathString: #keyPath(ChannelDTO.isHidden)) }

    /// A filter key for matching the `memberCount` value.
    /// Supported operators: `equal`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `notEqual`
    static var memberCount: FilterKey<Scope, Int> { .init(rawValue: "member_count", keyPathString: #keyPath(ChannelDTO.memberCount)) }

    /// A filter key for matching the `team` value.
    /// Supported operators: `equal`
    static var team: FilterKey<Scope, TeamId?> { .init(rawValue: "team", keyPathString: #keyPath(ChannelDTO.team)) }

    /// Filter for checking whether current user is joined the channel or not (through invite or directly)
    /// Supported operators: `equal`.
    static var joined: FilterKey<Scope, Bool> { .init(
        rawValue: "joined",
        keyPathString: #keyPath(ChannelDTO.membership),
        predicateMapper: { op, joined in
            let key = #keyPath(ChannelDTO.membership)
            switch op {
            case .equal:
                return NSPredicate(format: joined ? "\(key) != nil" : "\(key) == nil")
            default:
                return nil
            }
        }
    )}
    /// Supported operator: `contains`
    static var unread: FilterKey<Scope, String> {
        .init(rawValue: "unreadMessageCount",
              keyPathString: #keyPath(ChannelDTO.reads),
              predicateMapper: { op, userId in
            let key = #keyPath(ChannelDTO.reads)
            return NSPredicate(format: "SUBQUERY(%K, $r, $r.user.id == %@ AND $r.unreadMessageCount > 0).@count > 0", key, "\(userId)")
        })
    }

    /// Filter for invited channels where user not accept or reject
    /// Supported operator: `equal`
    static var channelRoles: FilterKey<Scope, String> { .init(
        rawValue: "roles",
        keyPathString: #keyPath(ChannelDTO.membership.channelRoleRaw)
    )
    }

    /// FIlter for channel in projectId
    /// Spported operator: 'equal'
    static var projectId: FilterKey<Scope, String> {
        .init(rawValue: "project_id",
              keyPathString: #keyPath(ChannelDTO.cid),
              predicateMapper: { op, projectId in
            let key = #keyPath(ChannelDTO.cid)
            return NSPredicate(format: "\(key) contains %@", projectId)
        })
    }

    /// Filter for checking the status of the invite
    /// Supported operators: `equal`
    static var invite: FilterKey<Scope, InviteFilterValue> { "invite" }

    /// Filter for checking the `name` property of a user who is a member of the channel
    /// Supported operators: `equal`, `notEqual`, `autocomplete`
    /// - Warning: This filter is considerably expensive for the backend so avoid using this when possible.
    static var memberName: FilterKey<Scope, String> { .init(rawValue: "member.user.name", keyPathString: #keyPath(ChannelDTO.members.user.name), isCollectionFilter: true) }

    /// Filter for the time of the last message in the channel. If the channel has no messages, then the time the channel was created.
    /// Supported operators: `equal`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `notEqual`
    static var lastUpdatedAt: FilterKey<Scope, Date> { .init(rawValue: "last_updated", keyPathString: #keyPath(ChannelDTO.lastMessageAt)) }
}

/// A query is used for querying specific channels from backend.
/// You can specify filter, sorting, pagination, limit for fetched messages in channel and other options.
public struct ChannelListQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case filter = "filter_conditions"
        case sort
        case user = "user_details"
        case state
        case watch
        case presence
        case pagination
        case messagesLimit = "message_limit"
        case membersLimit = "member_limit"
        case type
        case isPending = "is_pending"
    }

    /// A filter for the query (see `Filter`).
    public let filter: Filter<ChannelListFilterScope>
    /// A sorting for the query (see `Sorting`).
    public let sort: [Sorting<ChannelListSortingKey>]
    /// A pagination.
    public var pagination: Pagination
    /// A number of messages inside each channel.
    public let messagesLimit: Int
    /// Number of members inside each channel.
    public let membersLimit: Int

    /// Init a channels query.
    /// - Parameters:
    ///   - filter: a channels filter.
    ///   - sort: a sorting list for channels.
    ///   - pageSize: a page size for pagination.
    ///   - messagesLimit: a number of messages for the channel to be retrieved.
    public init(
        filter: Filter<ChannelListFilterScope>,
        sort: [Sorting<ChannelListSortingKey>] = [],
        pageSize: Int = .channelsPageSize,
        messagesLimit: Int = .messagesPageSize,
        membersLimit: Int = .channelMembersPageSize
    ) {
        self.filter = filter
        self.sort = sort
        pagination = Pagination(pageSize: pageSize)
        self.messagesLimit = messagesLimit
        self.membersLimit = membersLimit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filter, forKey: .filter)

        if !sort.isEmpty {
            try container.encode(sort, forKey: .sort)
        }

        try container.encode(messagesLimit, forKey: .messagesLimit)
        try container.encode(membersLimit, forKey: .membersLimit)
        try pagination.encode(to: encoder)
    }
}

extension ChannelListQuery: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Filter: \(filter) | Sort: \(sort)"
    }
}

public struct UserFilterValue: FilterValue {
    let userId: UserId
    let projectId: String

    enum CodingKeys: CodingKey {
        case userId
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.userId, forKey: .userId)
    }
}
