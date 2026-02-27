//
// Copyright 2025 Ermis Inc.
//

import Foundation
/// Triggered when a received a call signal.
public struct CallSignalEvent: Event, Encodable {
    public let userId: String?
    /// The identifier of call session.
    public var sessionId: String
    /// The identifier of the call.
    public var callId: String
    /// The identifier of deleted channel.
    public var cid: ChannelId { channel.cid }
    /// The truncated channel.
    public let channel: Channel
    /// Call action of the event.
    public let callAction: CallAction
    /// The type of the call. `true` is call is Video call.
    public let isVideo: Bool?
    /// The event timestamp.
    public let createdAt: Date

    public let metadata: Metadata?

    public init(userId: String?, sessionId: String, callId: String, channel: Channel, callAction: CallAction, isVideo: Bool?, createdAt: Date, metadata: Metadata?) {
        self.userId = userId
        self.sessionId = sessionId
        self.callId = callId
        self.channel = channel
        self.callAction = callAction
        self.isVideo = isVideo
        self.createdAt = createdAt
        self.metadata = metadata
    }

    public func encode(to encoder: any Encoder) throws {
        typealias CodingKeys = EventPayload.CodingKeys
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(callId, forKey: .callId)
        try container.encode(cid, forKey: .cid)
        try container.encode(callAction, forKey: .callAction)
        try container.encode(isVideo, forKey: .isVideo)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode("signal", forKey: .eventType)
        try container.encode(metadata, forKey: .metadata)
    }
}
