//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

extension ChannelCapability {
    public var title: String {
        switch self {
        case .sendMessage:
            return L10n.ChannelCapability.sendMessages
        case .sendLinks:
            return L10n.ChannelCapability.sendLinks
        case .updateOwnMessage:
            return L10n.ChannelCapability.updateOwnMessages
        case .deleteOwnMessage:
            return L10n.ChannelCapability.deleteOwnMessages
        case .sendReaction:
            return L10n.ChannelCapability.sendReaction
        case .pinMessage:
            return L10n.ChannelCapability.pinMessages
        default:
            return ""
        }
    }
}
