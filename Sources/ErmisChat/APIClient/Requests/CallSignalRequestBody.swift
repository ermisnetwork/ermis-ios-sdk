//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct CallSignalRequestBody: Encodable {
    let sessionId: String
    let callId: String?
    let cid: ChannelId
    let action: CallAction
    let isVideo: Bool
    let signal: CallSignal?
    let ios = true
    let metadata: Metadata?

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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionId, forKey: .sesionId)
        try container.encodeIfPresent(self.callId, forKey: .callId)
        try container.encode(self.cid, forKey: .cid)
        try container.encode(self.action, forKey: .action)
        try container.encode(self.isVideo, forKey: .isVideo)
        try container.encodeIfPresent(self.signal, forKey: .signal)
        try container.encode(ios, forKey: .ios)
        try container.encode(metadata, forKey: .metadata)
    }
}

public struct Metadata: Codable {
    public let address: String?

    public init(localAddress: String?) {
        self.address = localAddress
    }
}
