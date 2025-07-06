//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The middleware listens for `ChannelHidden/Visible` events and updates `ChannelDTO` accordingly.
struct ChannelVisibilityEventMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        do {
            switch event {
            case let event as ChannelDeletedEventDTO:
                guard let channelDTO = session.channel(cid: event.channel.cid) else {
                    return event
                }
                channelDTO.deletedAt = event.channel.updatedAt.bridgeDate
            case let event as ChannelVisibleEventDTO:
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }

                channelDTO.isHidden = false

            case let event as ChannelHiddenEventDTO:
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }

                channelDTO.isHidden = true

                if event.isHistoryCleared {
                    channelDTO.truncatedAt = event.createdAt.bridgeDate
                }

            case let event as ChannelPinnedEventDTO:
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }
                channelDTO.isPinned = true

            case let event as ChannelUnpinnedEventDTO:
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }
                channelDTO.isPinned = false

            // New Message will unhide the channel
            // but we won't get `ChannelVisibleEvent` for this case
            case let event as MessageNewEventDTO:
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }

                if !event.message.isShadowed {
                    channelDTO.isHidden = false
                }

            // New Message will unhide the channel
            // but we won't get `ChannelVisibleEvent` for this case
            case let event as NotificationMessageNewEventDTO:
                guard let channelDTO = session.channel(cid: event.channel.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.channel.cid)
                }

                if !event.message.isShadowed {
                    channelDTO.isHidden = false
                }

            default:
                break
            }
        } catch {
            log.error("Failed to write changes from \(event) to the database. Error: \(error)")
        }

        return event
    }
}
