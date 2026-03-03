//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The middleware listens for `ChannelTruncatedEventMiddleware` events and updates `ChannelDTO` accordingly.
struct ChannelTruncatedEventMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        guard
            let truncatedEvent = event as? ChannelTruncatedEventDTO
        else {
            return event
        }

        do {
            let cid = truncatedEvent.cid
            guard let channelDTO = session.channel(cid: cid) else {
                throw ClientError.ChannelDoesNotExist(cid: cid)
            }

            channelDTO.truncatedAt = truncatedEvent.createdAt.bridgeDate

            // Clear all messages except local-only ones
            channelDTO.cleanAllMessagesExcludingLocalOnly()

            // Clear all read states for all users in this channel
            channelDTO.reads.forEach { read in
                read.lastReadMessageId = nil
                read.lastReadAt = truncatedEvent.createdAt.bridgeDate ?? DBDate()
                read.unreadMessageCount = 0
            }
            
            // Also ensure the current user's read state is cleared
            if let userId = truncatedEvent.user?.id, let read = session.loadChannelRead(cid: cid, userId: userId) {
                read.lastReadMessageId = nil
                read.lastReadAt = truncatedEvent.createdAt.bridgeDate ?? DBDate()
                read.unreadMessageCount = 0
            }
        } catch {
            log.error("Failed to write the `truncatedAt` field update in the database, error: \(error)")
        }
        return event
    }
}
