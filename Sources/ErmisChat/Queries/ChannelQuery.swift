//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A channel query.
public struct ChannelQuery: Encodable {
    enum CodingKeys: String, CodingKey {
        case data
        case messages
        case members
        case watchers
        case projectId = "project_id"
        case parentCid = "parent_cid"
        case topicCid = "topic_cid"
    }

    /// Channel id this query handles.
    public let id: String?
    /// Channel type this query handles.
    public let type: ChannelType
    /// A pagination for messages (see `MessagesPagination`).
    public var pagination: MessagesPagination?
    /// A number of members for the channel to be retrieved.
    public let membersLimit: Int?
    /// A number of watchers for the channel to be retrieved.
    public let watchersLimit: Int?
    /// ChannelCreatePayload that is needed only when creating channel
    var channelPayload: ChannelEditDetailPayload?

    /// The project id this query handles.
    let projectId: String
    
    /// The parent channel id this query handles, if any.
    let parentCid: ChannelId?
    
    /// The topic channel id this query handles, if any.
    let topicCid: ChannelId?

    var mlsEnabled: Bool?

    /// `ChannelId` this query handles.
    /// If `id` part is missing then it's impossible to create valid `ChannelId`.
    public var cid: ChannelId? {
        id.map { ChannelId(type: type, id: $0) }
    }

    /// Init a channel query.
    /// - Parameters:
    ///   - cid: a channel cid.
    ///   - pageSize: a page size for pagination.
    ///   - paginationParameter: the pagination configuration.
    ///   - membersLimit: a number of members for the channel  to be retrieved.
    ///   - watchersLimit: a number of watchers for the channel to be retrieved.
    ///   - mslEnabled: a boolean value for the encryption state of the channel.
    public init(
        cid: ChannelId,
        parentCid: ChannelId? = nil,
        topicCid: ChannelId? = nil,
        pageSize: Int? = .messagesPageSize,
        paginationParameter: PaginationParameter? = nil,
        membersLimit: Int? = nil,
        watchersLimit: Int? = nil,
        mlsEnabled: Bool? = nil
    ) {
        id = cid.id
        type = cid.type
        channelPayload = nil

        pagination = MessagesPagination(pageSize: pageSize ?? .messagesPageSize, parameter: paginationParameter)
        self.parentCid = parentCid
        self.membersLimit = membersLimit
        self.watchersLimit = watchersLimit
        self.projectId = cid.projectId
        self.topicCid = topicCid
        self.mlsEnabled = mlsEnabled
    }

    /// Init a channel query.
    /// - Parameters:
    ///   - channelPayload: a payload that has data needed for channel creation.
    init(channelPayload: ChannelEditDetailPayload,
         projectId: String,
         parentCid: ChannelId? = nil,
         topicCid: ChannelId? = nil,
         mlsEnabled: Bool? = nil) {
        id = channelPayload.id
        type = channelPayload.type
        self.channelPayload = channelPayload
        pagination = nil
        membersLimit = nil
        watchersLimit = nil
        self.parentCid = parentCid
        self.projectId = projectId
        self.topicCid = topicCid
        self.mlsEnabled = mlsEnabled
    }

    /// Init a channel query.
    /// - Parameters:
    ///   - cid: New `ChannelId` for channel query..
    ///   - channelQuery: ChannelQuery with old cid.
    init(cid: ChannelId, channelQuery: Self) {
        self.init(
            cid: cid,
            pageSize: channelQuery.pagination?.pageSize,
            paginationParameter: channelQuery.pagination?.parameter,
            membersLimit: channelQuery.membersLimit,
            watchersLimit: channelQuery.watchersLimit,
            mlsEnabled: channelQuery.mlsEnabled
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Only needed for channel creation
        try container.encodeIfPresent(channelPayload, forKey: .data)

        try pagination.map { try container.encode($0, forKey: .messages) }
        try membersLimit.map { try container.encode(Pagination(pageSize: $0), forKey: .members) }
        try watchersLimit.map { try container.encode(Pagination(pageSize: $0), forKey: .watchers) }
        try container.encodeIfPresent(projectId, forKey: .projectId)
        if let parentCid = parentCid {
            try container.encode(parentCid.rawValue, forKey: .parentCid)
        }
        
        if let topicCid = topicCid {
            try container.encode(topicCid.rawValue, forKey: .topicCid)
        }

    }
}

extension ChannelQuery: APIPathConvertible {
    var apiPath: String { cid?.apiPath ?? type.rawValue }
}

/// An answer for an invite to a channel.
struct ChannelInvitePayload: Encodable {
    struct Message: Encodable {
        let message: String?
    }

    private enum CodingKeys: String, CodingKey {
        case accept = "accept_invite"
        case reject = "reject_invite"
        case message
    }

    /// Accept the invite.
    let accept: Bool?
    /// Reject the invite.
    let reject: Bool?
    /// Additional message.
    let message: Message?
}
