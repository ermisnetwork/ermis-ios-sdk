//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public
protocol SystemMessageFormatter {
    func format(systemMessage: SystemMessage, in channel: Channel) -> String?
}

public
class DefaultSystemMessageFormatter: SystemMessageFormatter {
    public
    required init() {

    }

    public
    func format(systemMessage: SystemMessage, in channel: Channel) -> String? {
        switch systemMessage {
        case .channelNameUpdated(userId: let userId, channelName: let channelName):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.channelNameUpdated(userName, !channelName.isEmpty ? channelName : (channel.name ?? ""))
        case .channelImageUpdated(let userId):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.channelImageUpdated(userName)
        case .channelDescriptionUpdated(let userId):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.channelDesciptionUpdated(userName)
        case .memberRemoved(let userId):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.memberRemoved(userName)
        case .memberBanned(let userId):
            if userId == channel.membership?.userId {
                return L10n.Message.System.youBanned
            } else {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.memberBanned(userName)
            }
        case .memberUnbanned(let userId):
            if userId == channel.membership?.userId {
                return L10n.Message.System.youUnbanned
            } else {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.memberUnbanned(userName)
            }
        case .memberPromoted(let userId):
            if userId == channel.membership?.userId {
                return L10n.Message.System.youPromoted
            } else {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.memberPromoted(userName)
            }
        case .memberDemoted(let userId):
            if userId == channel.membership?.userId {
                return L10n.Message.System.youDemoted
            } else {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.memberDemoted(userName)
            }
        case .memberCapabilitiesUpdated(let userId):
            if userId == channel.membership?.userId {
                return L10n.Message.System.youUpdatedMemberPermission
            } else {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.otherUpdatedMemberPermission(userName)
            }
        case .inviteAccepted(let userId):
            if channel.isDirectMessageChannel {
                if userId == channel.membership?.userId {
                    return L10n.Message.System.youJoinedConversation
                } else {
                    let userName = userName(of: userId, in: channel)
                    return L10n.Message.System.memberJoinedConversation(userName)
                }
            } else {
                if userId == channel.membership?.userId {
                    return L10n.Message.System.youJoinedChannel
                } else {
                    let userName = userName(of: userId, in: channel)
                    return L10n.Message.System.memberJoinedChannel(userName)
                }
            }
        case .inviteRejected(let userId):
            if !channel.isDirectMessageChannel {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.userRejectedInvitation(userName)
            }
            return nil
        case .leaveChannel(let userId):
            if userId == channel.membership?.userId {
                return L10n.Message.System.youLeave
            } else {
                let userName = userName(of: userId, in: channel)
                return L10n.Message.System.memberLeave(userName)
            }
        case .channelPublicUpdated(userId: let userId, isPublic: let isPublic):
            if userId == channel.membership?.userId {
                return isPublic ? L10n.Message.System.youSetChannelPublic : L10n.Message.System.youSetChannelPrivate
            } else {
                let userName = userName(of: userId, in: channel)
                return isPublic ? L10n.Message.System.setChannelPublic(userName) : L10n.Message.System.setChannelPrivate(userName)
            }
        case .memberMessageCoolDown(let userId, let duration):
            if duration == 0 {
                return L10n.Message.System.turnOffCooldown
            } else {
                let formater = DateComponentsFormatter()
                formater.allowedUnits = [.minute, .second]
                formater.zeroFormattingBehavior = .dropAll
                formater.unitsStyle = .full
                let durationString = formater.string(from: TimeInterval(duration)) ?? ""
                return L10n.Message.System.adjustCooldown(durationString)
            }
        case .channelFilterKeywordsUpdated(let userId):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.filterWordsChanged(userName)
        case .messagePinned(let userId, let messageId):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.messagePinned(userName)
        case .messageUnpinned(userId: let userId, messageId: let messageId):
            let userName = userName(of: userId, in: channel)
            return L10n.Message.System.messageUnpinned(userName)
        @unknown default:
            return nil
        }
    }

    func userName(of userId: String, in channel: Channel) -> String {
        let member = channel.lastActiveMembers.first(where:  { $0.userId == userId})
        return member?.name ?? userId
    }
}

