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

    public var title: String {
        switch self {
        case .muted:
            return "Until i turn it back on"
        case .mutedForDuration(let duration):
            let timeInterval = TimeInterval(duration / 1000)
            let formater = DateComponentsFormatter()
            formater.allowedUnits = [.hour, .minute, .second]
            formater.unitsStyle = .full
            formater.zeroFormattingBehavior = .dropAll
            let timeString = formater.string(from: timeInterval)
            return "Mute for \(timeString ?? "")"
        case .unMuted:
            return "Unmute"
        }
    }
}

