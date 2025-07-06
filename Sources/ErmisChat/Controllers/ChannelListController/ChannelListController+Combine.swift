//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension ChannelListController {
    /// A publisher emitting a new value every time the state of the controller changes.
    public var statePublisher: AnyPublisher<DataController.State, Never> {
        basePublishers.state.keepAlive(self)
    }

    /// A publisher emitting a new value every time the list of the channels matching the query changes.
    public var channelsChangesPublisher: AnyPublisher<[ListChange<Channel>], Never> {
        basePublishers.channelsChanges.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapper controller
        unowned let controller: ChannelListController

        /// A backing subject for `statePublisher`.
        let state: CurrentValueSubject<DataController.State, Never>

        /// A backing subject for `channelsChangesPublisher`.
        let channelsChanges: PassthroughSubject<[ListChange<Channel>], Never> = .init()

        init(controller: ChannelListController) {
            self.controller = controller
            state = .init(controller.state)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension ChannelListController.BasePublishers: ChannelListControllerDelegate {
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state.send(state)
    }

    func controller(
        _ controller: ChannelListController,
        didChangeChannels changes: [ListChange<Channel>]
    ) {
        channelsChanges.send(changes)
    }
}
