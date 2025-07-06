//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
struct ErmisErrorPayload: Decodable {
    /// An ermis api error code.
    public let ermisCode: Int
    /// A error message.
    public let message: String
    /// A channel conditions if have
    public let channelCondtions: [ChannelConditionPayload]?

    enum CodingKeys: String, CodingKey {
        case ermisCode = "ermis_code"
        case message
        case channelConditions = "channel_conditions"
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ermisCode = try container.decode(Int.self, forKey: .ermisCode)
        self.message = try container.decode(String.self, forKey: .message)
        self.channelCondtions = try container.decodeIfPresent([ChannelConditionPayload].self,
                                                              forKey: .channelConditions)
    }

    init(ermisCode: Int, message: String) {
        self.ermisCode = ermisCode
        self.message = message
        self.channelCondtions = nil
    }

    public
    var description: String {
        "Ermis api error - #\(ermisCode) message: \(message)"
    }
}

public
struct WebSocketErrorPayload: LocalizedError, Decodable {
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case statusCode = "StatusCode"
    }

    /// An error code.
    public let code: Int
    /// An error message.
    public let message: String
    /// A http status code.
    public let statusCode: Int
}
