//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct ChannelMutepayload: Codable {
    public let mute: Bool
    public let duration: Int?

    init(mute: Bool, duration: Int?) {
        self.mute = mute
        self.duration = duration
    }

    public init(from muteType: ChannelMuteType) {
        self.mute = muteType.isMuted
        if case .mutedForDuration(let duration) = muteType {
            self.duration = duration
        } else {
            self.duration = nil
        }
    }

    public
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.mute, forKey: .mute)
        try container.encodeIfPresent(self.duration, forKey: .duration)
    }
}

public
enum ChannelMuteType: Equatable {
    case muted // Mute forever until user unmute
    case mutedForDuration(Int) // Mute for duration in miliseconds
    case unMuted // Unmuted

    public var isMuted: Bool {
        switch self {
        case .muted, .mutedForDuration:
            return true
        case .unMuted:
            return false
        }
    }
}

