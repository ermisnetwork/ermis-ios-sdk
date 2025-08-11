//
//  ChannelTopicEvent.swift
//  ErmisChat
//
//  Created by Tú Đinh on 1/8/25.
//

import Foundation

struct ChannelTopicEventMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        guard let topicEvent = event as? ChannelTopicCreatedEventDTO else {
            return event
        }

        do {
            if let channel = session.channel(cid: topicEvent.parentCid) {
                let payload = ChannelPayload(channel: topicEvent.channel,
                                             watcherCount: nil,
                                             watchers: nil,
                                             membership: nil,
                                             messages: [],
                                             pinnedMessages: [],
                                             channelReads: [],
                                             isHidden: false,
                                             isPinned: false,
                                             topics: [])
                try session.saveChannel(payload: payload)
            }
        } catch {
            log.error("Failed to write the `truncatedAt` field update in the database, error: \(error)")
        }

        return event
    }
}
