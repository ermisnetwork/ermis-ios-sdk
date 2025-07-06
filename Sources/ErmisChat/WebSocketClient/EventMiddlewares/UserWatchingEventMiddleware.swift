//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The middleware listens for `UserWatchingEvent`s and updates `ChannelDTO`s accordingly.
struct UserWatchingEventMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        guard let userWatchingEvent = event as? UserWatchingEventDTO else { return event }

        do {
            guard let channelDTO = session.channel(cid: userWatchingEvent.cid) else {
                let currentUserId = session.currentUser?.user(of: userWatchingEvent.cid.projectId)?.userId
                if userWatchingEvent.user.id == currentUserId {
                    log.info(
                        "Ignoring watcher event for channel \(userWatchingEvent.cid) and current user"
                            + "since Channel doesn't exist locally."
                    )
                } else {
                    log.error(
                        "Failed to save watcher event for channel \(userWatchingEvent.cid)"
                        + "and user \(userWatchingEvent.user.userId) since Channel doesn't exist locally."
                    )
                }
                return event
            }
            guard let userDTO = session.user(id: userWatchingEvent.user.userId,
                                             projectId: userWatchingEvent.cid.projectId) else {
                throw ClientError.UserDoesNotExist(userId: userWatchingEvent.user.userId)
            }

            if userWatchingEvent.isStarted {
                userDTO.isOnline = true
                channelDTO.watchers.insert(userDTO)
            } else {
                userDTO.isOnline = false
                channelDTO.watchers.remove(userDTO)
            }
        } catch {
            log.error("Failed to update channel watchers in the database, error: \(error)")
        }

        return event
    }
}
