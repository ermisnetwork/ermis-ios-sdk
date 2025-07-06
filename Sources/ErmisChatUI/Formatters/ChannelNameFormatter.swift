//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

/// A formatter that generates a name for the given channel.
public protocol ChannelNameFormatter {
    func format(channel: Channel, forCurrentUserId currentUserId: UserId?) -> String?
}

/// The default channel name formatter.
open class DefaultChannelNameFormatter: ChannelNameFormatter {
    public init() {}

    /// Internal static property to add backwards compatibility to `Components.channelNamer`
    internal static var channelNamer: (
        _ channel: Channel,
        _ currentUserId: UserId?
    ) -> String? = DefaultChannelNamer()

    open func format(channel: Channel, forCurrentUserId currentUserId: UserId?) -> String? {
        Self.channelNamer(channel, currentUserId)
    }
}
