//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.audioEnable = try container.decode(Bool.self, forKey: .audioEnable)
        self.videoEnable = try container.decode(Bool.self, forKey: .videoEnable)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioEnable, forKey: .audioEnable)
        try container.encode(videoEnable, forKey: .videoEnable)
    }

    var description: String {
        "TransciverState(audioEnable: \(audioEnable), videoEnable: \(videoEnable))"
    }
}
