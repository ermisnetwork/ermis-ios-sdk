//
// Copyright 2025 Ermis Inc.
//

import Foundation

public extension ErmisClient {
    /// Creates a new `ChannelEventsController` that can be used to listen to system events
    /// related to the channel with `cid` and to send custom events.
    ///
    /// - Parameter cid: A channel identifier.
    /// - Returns: A new instance of `ChannelEventsController`.
    func channelEventsController(for cid: ChannelId) -> ChannelEventsController {
        .init(
            cidProvider: { cid },
            notificationCenter: eventNotificationCenter
        )
    }
}

public extension ChannelController {
    /// Creates a new `ChannelEventsController` that can be used to listen to system events
    /// and for sending custom events into a channel the current controller manages.
    ///
    /// - Returns: A new instance of `ChannelEventsController`.
    func eventsController() -> ChannelEventsController {
        .init(
            cidProvider: { self.cid },
            notificationCenter: client.eventNotificationCenter
        )
    }
}

/// `ChannelEventsController` is a controller class which allows to observe channel
/// events and send custom events.
public class ChannelEventsController: EventsController {
    // A channel identifier provider.
    private let cidProvider: () -> ChannelId?

    // A channel identifier. Returns `nil` if channel has not yet created.
    public var cid: ChannelId? { cidProvider() }

    /// Creates a instance of `ChannelEventsController` type.
    /// - Parameters:
    ///   - cid: A channel identifier.
    ///   - notificationCenter: A notification center.
    init(
        cidProvider: @escaping () -> ChannelId?,
        notificationCenter: EventNotificationCenter
    ) {
        self.cidProvider = cidProvider

        super.init(notificationCenter: notificationCenter)
    }

    override func shouldProcessEvent(_ event: Event) -> Bool {
        guard let cid = cid else { return false }

        let channelEvent = event as? ChannelSpecificEvent
        let unknownEvent = event as? UnknownChannelEvent

        return channelEvent?.cid == cid || unknownEvent?.cid == cid
    }
}
