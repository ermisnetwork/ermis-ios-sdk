//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension StickerController {
    /// A publisher emitting a new value every time the state of the controller changes.
    public var statePublisher: AnyPublisher<DataController.State, Never> {
        basePublishers.state.keepAlive(self)
    }

    /// A publisher emitting a new value every time the list of the stickerPack matching the query changes.
    public var stickerPacksChangesPublisher: AnyPublisher<[ListChange<StickerPack>], Never> {
        basePublishers.stickerPackChanges.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapper controller
        unowned let controller: StickerController

        /// A backing subject for `statePublisher`.
        let state: CurrentValueSubject<DataController.State, Never>

        /// A backing subject for `channelsChangesPublisher`.
        let stickerPackChanges: PassthroughSubject<[ListChange<StickerPack>], Never> = .init()

        init(controller: StickerController) {
            self.controller = controller
            state = .init(controller.state)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension StickerController.BasePublishers: StickerControllerDelegate {
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state.send(state)
    }

    func controller(
        _ controller: ChannelListController,
        didChangeStickerPack changes: [ListChange<StickerPack>]
    ) {
        stickerPackChanges.send(changes)
    }
}
