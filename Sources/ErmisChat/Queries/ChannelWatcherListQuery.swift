//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A query type used for fetching a channel's watchers from the backend.
///
public struct ChannelWatcherListQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case watchers
    }

    /// A pagination for watchers (see `Pagination`).
    public var pagination: Pagination

    /// `ChannelId` this query handles.
    public var cid: ChannelId
    /// Creates new `ChannelWatcherListQuery` instance.
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - pagination: Pagination parameters for fetching watchers. Defaults to fetching first 30 watchers.
    public init(cid: ChannelId, pagination: Pagination = .init(pageSize: .channelWatchersPageSize)) {
        self.cid = cid
        self.pagination = pagination
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pagination, forKey: .watchers)
    }
}
