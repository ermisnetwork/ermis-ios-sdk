//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import ErmisChatUI
import Foundation

public protocol SignalMessageFormatter {
    func format(signalMessage: SignalMessage, in channel: Channel) -> String?
}

public class DefaultSignalMessageFormatter: SignalMessageFormatter {
    public func format(signalMessage: SignalMessage, in channel: Channel) -> String? {
        guard let callEndedReson = signalMessage.endedReason else {
            return "Start call"
        }
        let isSentByCurrentUser = signalMessage.senderId == channel.membership?.userId
        let isVideo = signalMessage.isVideo
        switch callEndedReson {
        case .cancelled:
            return isSentByCurrentUser ? cancelCallMessage(isVideo) : missedCallMessage(isVideo)
        case .noAnswer:
            return isSentByCurrentUser ? outgoingCallMessage(isVideo) : missedCallMessage(isVideo)
        case .rejected:
            return isSentByCurrentUser ? outgoingCallMessage(isVideo) : incomingCallMessage(isVideo)
        case .busy:
            return isSentByCurrentUser ? outgoingCallMessage(isVideo) : missedCallMessage(isVideo)
        case .normal:
            return isSentByCurrentUser ? outgoingCallMessage(isVideo) : incomingCallMessage(isVideo)
        }
    }

    func userName(of userId: String, in channel: Channel) -> String {
        let member = channel.lastActiveMembers.first(where:  { $0.userId == userId})
        return member?.name ?? userId
    }

    func cancelCallMessage(_ isVideo: Bool) -> String {
        return isVideo ? L10n.ChannelList.LastMessage.cancelVideoCall : L10n.ChannelList.LastMessage.cancelAudioCall
    }

    func outgoingCallMessage(_ isVideo: Bool) -> String {
        return isVideo ? L10n.ChannelList.LastMessage.outgoingVideoCall : L10n.ChannelList.LastMessage.outgoingAudioCall
    }

    func incomingCallMessage(_ isVideo: Bool) -> String {
        return isVideo ? L10n.ChannelList.LastMessage.incomingVideoCall : L10n.ChannelList.LastMessage.incomingAudioCall
    }

    func missedCallMessage(_ isVideo: Bool) -> String {
        return isVideo ? L10n.ChannelList.LastMessage.missedVideoCall : L10n.ChannelList.LastMessage.missedAudioCall
    }
}
