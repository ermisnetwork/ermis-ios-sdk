//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct CallSignalRequestBody: Encodable {
    let sessionId: String
    let callId: String?
    let cid: ChannelId
    let action: CallAction
    let isVideo: Bool
    let ios = true
    let metadata: Metadata?

    public init(sessionId: String, callId: String?, cid: ChannelId, action: CallAction, isVideo: Bool, metadata: Metadata?) {
        self.sessionId = sessionId
        self.callId = callId
        self.cid = cid
        self.action = action
        self.isVideo = isVideo
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case sesionId = "session_id"
        case callId = "call_id"
        case cid
        case action
        case isVideo = "is_video"
        case signal
        case ios
        case metadata
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionId, forKey: .sesionId)
        try container.encodeIfPresent(self.callId, forKey: .callId)
        try container.encode(self.cid, forKey: .cid)
        try container.encode(self.action, forKey: .action)
        try container.encode(self.isVideo, forKey: .isVideo)
        try container.encode(ios, forKey: .ios)
        try container.encode(metadata, forKey: .metadata)
    }
}
