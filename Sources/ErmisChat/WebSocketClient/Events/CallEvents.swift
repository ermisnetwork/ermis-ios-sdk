//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
class CallSignalEventDTO: EventDTO {
    public let userId:String?
    public let sessionId: String
    public let callId: String
    public let cid: ChannelId
    public let callAction: CallAction
    public let isVideo: Bool?
    public let signal: CallSignal?
    public let createdAt: Date
    public let metadata: Metadata?
    let payload: EventPayload

    init(from response: EventPayload) throws {
        userId = try? response.value(at: \.userId)
        sessionId = try response.value(at: \.sessionId)
        callId = try response.value(at: \.callId)
        cid = try response.value(at: \.cid)
        callAction = try response.value(at: \.callAction)
        isVideo = try? response.value(at: \.isVideo)
        signal = try? response.value(at: \.signal)
        createdAt = try response.value(at: \.createdAt)
        metadata = try? response.value(at: \.metadata)
        payload = response
    }

    func toDomainEvent(session: any DatabaseSession) -> (any Event)? {
        guard let channelDTO = session.channel(cid: cid) else { return nil }
        return try? CallSignalEvent(userId: userId,
                                    sessionId: sessionId,
                                    callId: callId,
                                    channel: channelDTO.asModel(),
                                    callAction: callAction,
                                    isVideo: isVideo,
                                    signal: signal,
                                    createdAt: createdAt, metadata: metadata)
    }
}


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
    /// The call signal of the event.
    public let signal: CallSignal?
    /// The event timestamp.
    public let createdAt: Date

    public let metadata: Metadata?

    public func encode(to encoder: any Encoder) throws {
        typealias CodingKeys = EventPayload.CodingKeys
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(callId, forKey: .callId)
        try container.encode(cid, forKey: .cid)
        try container.encode(callAction, forKey: .callAction)
        try container.encode(isVideo, forKey: .isVideo)
        try container.encode(signal, forKey: .signal)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode("signal", forKey: .eventType)
        try container.encode(metadata, forKey: .metadata)
    }
}
