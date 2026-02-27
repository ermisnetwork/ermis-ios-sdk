//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

/// The middleware listens for `MemberEvent`s and updates `ChannelDTO`s accordingly.
struct MemberEventMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        do {
            switch event {
            case let event as MemberUpdatedEventDTO:
                try session.saveMember(payload: event.member, channelId: event.cid)
                if let channel = session.channel(cid: event.cid) {
                    if channel.membership?.user.userId == event.member.userId {
                        channel.membership = try session.saveMember(payload: event.member, channelId: event.cid)
                    }
                }
            case let event as MemberBannedEventDTO:
                try session.saveMember(payload: event.member, channelId: event.cid)
            case let event as MemberUnbannedEventDTO:
                try session.saveMember(payload: event.member, channelId: event.cid)
            case let event as MemberAddedEventDTO:
                if let channel = session.channel(cid: event.cid) {
                    let member = try session.saveMember(payload: event.member, channelId: event.cid)
                    if channel.membership?.user.userId == event.member.userId {
                        channel.membership = try session.saveMember(payload: event.member, channelId: event.cid)
                    }
                    insertMemberToMemberListQueries(channel, member)
                }
            case let event as MemberJoinnedEventDTO:
                if let channel = session.channel(cid: event.cid) {
                    let member = try session.saveMember(payload: event.member, channelId: event.cid)
                    if channel.membership == nil {
                        channel.membership = try session.saveMember(payload: event.member, channelId: event.cid)
                    }
                    insertMemberToMemberListQueries(channel, member)
                }
            case let event as MemberRemovedEventDTO:
                guard let channel = session.channel(cid: event.cid) else {
                    break
                }

                guard let member = channel.members.first(where: { $0.user.userId == event.member.userId }) else {
                    break
                }

                // Mark channel as unread
                session.markChannelAsUnread(cid: event.cid, by: event.member.userId)

                // We remove the member from the channel
                channel.members.remove(member)
                if let membership = channel.membership, membership.user.userId == event.member.userId {
                    channel.membership = nil
                }

                // If there are any MemberListQueries observing this channel,
                // we need to update them too
                member.queries.removeAll()

            case let event as MemberPromotedEventDTO:
                guard let channel = session.channel(cid: event.cid) else {
                    // No need to throw ChannelNotFound error here
                    break
                }

                guard let member = channel.members.first(where: { $0.user.userId == event.user.userId }) else {
                    // No need to throw MemberNotFound error here
                    break
                }

                member.channelRoleRaw = MemberRole.moderator.rawValue

                if let membership = channel.membership, membership.user.userId == event.user.userId {
                    channel.membership?.channelRoleRaw = MemberRole.moderator.rawValue
                }

            case let event as MemberDemotedEventDTO:
                guard let channel = session.channel(cid: event.cid) else {
                    // No need to throw ChannelNotFound error here
                    break
                }

                guard let member = channel.members.first(where: { $0.user.userId == event.user.userId }) else {
                    // No need to throw MemberNotFound error here
                    break
                }

                member.channelRoleRaw = MemberRole.member.rawValue

                if let membership = channel.membership, membership.user.userId == event.user.userId {
                    channel.membership?.channelRoleRaw = MemberRole.member.rawValue
                }

            case let event as NotificationChannelCreatedEventDTO:
                let channel = try session.saveChannel(payload: event.channel, query: nil, cache: nil)
                let member = try session.saveMember(payload: event.member, channelId: event.channel.cid)
                channel.membership = member

                insertMemberToMemberListQueries(channel, member)

            case let event as NotificationRemovedFromChannelEventDTO:
                guard let channel = session.channel(cid: event.cid) else {
                    // No need to throw ChannelNotFound error here
                    log.debug("Channel \(event.cid) not found for NotificationRemovedFromChannelEventDTO")
                    break
                }

                guard let member = channel.members.first(where: { $0.user.userId == event.member.userId }) else {
                    // No need to throw MemberNotFound error here
                    log.debug("Member \(event.member.userId) not found for NotificationRemovedFromChannelEventDTO")
                    break
                }

                // We remove the member from the channel
                channel.members.remove(member)
                // We reset membership since we're no longer a member
                channel.membership = nil

                // If there are any MemberListQueries observing this channel,
                // we need to update them too
                member.queries.removeAll()

            case let event as NotificationInviteAcceptedEventDTO:
                let channel = try session.channel(cid: event.cid)
                let member = try session.saveMember(payload: event.member, channelId: event.cid)
                if channel?.membership?.user.userId == member.user.userId {
                    channel?.membership = member
                }
            case let event as NotificationInviteSkippedEventDTO:
                let member = try session.saveMember(payload: event.member, channelId: event.cid)
                let channel = try session.channel(cid: event.cid)
                if channel?.membership?.user.userId == member.user.userId {
                    channel?.membership = member
                }
            case let event as NotificationInviteRejectedEventDTO:
                let channel = try session.channel(cid: event.cid)
                let member = try session.saveMember(payload: event.member, channelId: event.cid)
                channel?.members.remove(member)
                member.queries.removeAll()
            case let event as NotificationInviteMessagingRejectedEventDTO:
                let member = try session.saveMember(payload: event.member, channelId: event.cid)
                let channel = try session.channel(cid: event.cid)
                if channel?.membership?.user.userId == member.user.userId {
                    channel?.membership = member
                }
            case let event as NotificationInvitedEventDTO:
                guard let channel = session.channel(cid: event.cid) else {
                    // No need to throw ChannelNotFound error here
                    break
                }
                let member = try session.saveMember(payload: event.member, channelId: event.cid)
                channel.membership = member

                insertMemberToMemberListQueries(channel, member)

            default:
                break
            }
        } catch {
            log.error("Failed to update channel members in the database, error: \(error)")
        }

        return event
    }

    private func insertMemberToMemberListQueries(_ channel: ChannelDTO, _ member: MemberDTO) {
        // If there are any `MemberListQuery`s observing this Channel
        // without any filters (so the query observes all members)
        // the new Member should be linked to them too
        // so `MemberListController` works as expected
        // To make it work with queries with filters, we need to mirror `ChannelListController` logic
        // `shouldListUpdatedChannel` and such
        channel.memberListQueries.filter { $0.filterJSONData == nil }.forEach {
            $0.members.insert(member)
        }
    }
}
