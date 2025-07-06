//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension ChannelWatcherListController {
    /// A publisher emitting a new value every time the state of the controller changes.
    public var statePublisher: AnyPublisher<DataController.State, Never> {
        basePublishers.state.keepAlive(self)
    }

    /// A publisher emitting a new value every time the channel members change.
    public var watchersChangesPublisher: AnyPublisher<[ListChange<ChatUser>], Never> {
        basePublishers.watchersChanges.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapped controller.
        unowned let controller: ChannelWatcherListController

        /// A backing subject for `statePublisher`.
        let state: CurrentValueSubject<DataController.State, Never>

        /// A backing subject for `membersChangesPublisher`.
        let watchersChanges: PassthroughSubject<[ListChange<ChatUser>], Never> = .init()

        init(controller: ChannelWatcherListController) {
            self.controller = controller
            state = .init(controller.state)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension ChannelWatcherListController.BasePublishers: ChannelWatcherListControllerDelegate {
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state.send(state)
    }

    func channelWatcherListController(
        _ controller: ChannelWatcherListController,
        didChangeWatchers changes: [ListChange<ChatUser>]
    ) {
        watchersChanges.send(changes)
    }
}
