//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension ChannelMemberListController {
    /// A publisher emitting a new value every time the state of the controller changes.
    public var statePublisher: AnyPublisher<DataController.State, Never> {
        basePublishers.state.keepAlive(self)
    }

    /// A publisher emitting a new value every time the channel members change.
    public var membersChangesPublisher: AnyPublisher<[ListChange<ChannelMember>], Never> {
        basePublishers.membersChanges.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapped controller.
        unowned let controller: ChannelMemberListController

        /// A backing subject for `statePublisher`.
        let state: CurrentValueSubject<DataController.State, Never>

        /// A backing subject for `membersChangesPublisher`.
        let membersChanges: PassthroughSubject<[ListChange<ChannelMember>], Never> = .init()

        init(controller: ChannelMemberListController) {
            self.controller = controller
            state = .init(controller.state)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension ChannelMemberListController.BasePublishers: ChannelMemberListControllerDelegate {
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state.send(state)
    }

    func memberListController(
        _ controller: ChannelMemberListController,
        didChangeMembers changes: [ListChange<ChannelMember>]
    ) {
        membersChanges.send(changes)
    }
}
