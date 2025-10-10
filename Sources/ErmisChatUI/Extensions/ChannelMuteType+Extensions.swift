//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

extension ChannelMuteType {
    public var title: String {
        switch self {
        case .muted:
            return L10n.ChannelMuteType.untilITurnBack
        case .mutedForDuration(let duration):
            let timeInterval = TimeInterval(duration / 1000)
            let formater = DateComponentsFormatter()
            formater.allowedUnits = [.hour, .minute, .second]
            formater.unitsStyle = .full
            formater.zeroFormattingBehavior = .dropAll
            let timeString = formater.string(from: timeInterval)
            return L10n.ChannelMuteType.muteFor(timeString ?? "")
        case .unMuted:
            return L10n.ChannelMuteType.unmute
        }
    }
}


