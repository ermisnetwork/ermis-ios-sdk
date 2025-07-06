//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

/// Generates a name for the given channel, given the current user's id.
///
/// The priority order is:
/// - If the channel has name: return name.
/// - If the channel is direct message: return member's name or id.
/// - If the channel don't have name, and is not direct channel:
///   return name generated from channel member name.
/// - Otherwise: return nil.
///
/// - Parameters:
///   - maxMemberNames: Maximum number of members's name to generated channel
///     name, defaults to `2`
///   - separator: Separator charater between member's name when generate
///     channel name, default is ",".
/// - Returns: A closure with 2 parameters carrying `channel` used for name
///   generation and `currentUserId` to decide which members' names are going
///   to be displayed
public func DefaultChannelNamer(
    maxMemberNames: Int = 2,
    separator: String = ", "
) -> (_ channel: Channel, _ currentUserId: UserId?) -> String? {
    { channel, currentUserId in
        if channel.isDirectMessageChannel {
            let memberName = channel.directUserMembership?.displayName
            return memberName
        } else if let channelName = channel.name, !channelName.isEmpty {
            return channelName
        } else {
            let memberNames = channel.lastActiveMembers
                .filter { !$0.id.contains(currentUserId ?? "") }
                .compactMap { $0.name.isEmptyOrNil ? $0.userId : $0.name }
                .sorted()
            let prefixedMemberNames = memberNames.prefix(maxMemberNames)
            let channelName: String
            if prefixedMemberNames.isEmpty {
                if let currentUser = channel.lastActiveMembers.first(where: { $0.id == currentUserId }) {
                    channelName = currentUser.displayName
                } else {
                    return nil
                }
            } else {
                if memberNames.count > maxMemberNames {
                    channelName = prefixedMemberNames.joined(separator: separator) + L10n.Channel.Name.andXMore(memberNames.count - maxMemberNames)
                } else {
                    channelName = prefixedMemberNames.joined(separator: separator)
                }
            }
            return channelName
        }
    }
}
