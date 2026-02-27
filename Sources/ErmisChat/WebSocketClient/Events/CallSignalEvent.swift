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
                                    createdAt: createdAt, metadata: metadata)
    }
}
