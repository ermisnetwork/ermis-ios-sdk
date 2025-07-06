//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

enum DataChannelMessage: Codable {
    case transciverState(TransciverState)
    case endCall
    case healthCall

    enum CodingKeys: String, CodingKey {
        case type
        case body
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transciverState(let transciverState):
            try container.encode(DataChannelMessageType.tranciverState, forKey: .type)
            try container.encode(transciverState, forKey: .body)
        case .endCall:
            try container.encode(DataChannelMessageType.endCall, forKey: .type)
        case .healthCall:
            try container.encode(DataChannelMessageType.healthCall, forKey: .type)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(DataChannelMessageType.self, forKey: .type)
        switch type {
        case .tranciverState:
            let body = try container.decode(TransciverState.self, forKey: .body)
            self = .transciverState(body)
        case .endCall:
            self = .endCall
        case .healthCall:
            self = .healthCall
        }
    }

    var description: String {
        switch self {
        case .transciverState(let transciverState):
            return transciverState.description
        case .endCall:
            return "End call"
        case .healthCall:
            return "Health call"
        }
    }
}

enum DataChannelMessageType: String, Codable {
    case tranciverState = "transciver_state"
    case endCall = "end_call"
    case healthCall = "health_call"
}

public struct TransciverState: Codable {
    public let audioEnable: Bool
    public let videoEnable: Bool

    init(audioEnable: Bool, videoEnable: Bool) {
        self.audioEnable = audioEnable
        self.videoEnable = videoEnable
    }

    enum CodingKeys: String, CodingKey {
        case audioEnable = "audio_enable"
        case videoEnable = "video_enable"
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<TransciverState.CodingKeys> = try decoder.container(keyedBy: TransciverState.CodingKeys.self)
        self.audioEnable = try container.decode(Bool.self, forKey: TransciverState.CodingKeys.audioEnable)
        self.videoEnable = try container.decode(Bool.self, forKey: TransciverState.CodingKeys.videoEnable)
    }

    var description: String {
        "TransciverState(audioEnable: \(audioEnable), videoEnable: \(videoEnable))"
    }
}
