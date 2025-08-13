//
//  ChannelTopicEvent.swift
//  ErmisChat
//
//  Created by Tú Đinh on 1/8/25.
//

import Foundation

struct ChannelTopicEventMiddleware: EventMiddleware {
    func handle(event: Event, session: DatabaseSession) -> Event? {
        
        switch event {
        case let event as ChannelTopicCreatedEventDTO:
            do {
                let payload = ChannelPayload(channel: event.channel,
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
            } catch {
                log.error(
                    "Failed to write the `truncatedAt` field update in the database, error: \(error)"
                )
            }
        case let event as ChannelTopicClosedEventDTO:
            do {
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }
                
                channelDTO.isClosedTopic = true
            } catch {
                log.error(
                    "Failed to write the `truncatedAt` field update in the database, error: \(error)"
                )
            }
        case let event as ChannelTopicReopenedEventDTO:
            do {
                guard let channelDTO = session.channel(cid: event.cid) else {
                    throw ClientError.ChannelDoesNotExist(cid: event.cid)
                }
                
                channelDTO.isClosedTopic = false
            } catch {
                log.error(
                    "Failed to write the `truncatedAt` field update in the database, error: \(error)"
                )
            }
        default:
            
            
            break
        }
        
        return event

    }
}
