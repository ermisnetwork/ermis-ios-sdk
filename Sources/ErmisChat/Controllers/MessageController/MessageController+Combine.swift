//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension MessageController {
    /// A publisher emitting a new value every time the state of the controller changes.
    public var statePublisher: AnyPublisher<DataController.State, Never> {
        basePublishers.state.keepAlive(self)
    }

    /// A publisher emitting a new value every time the message changes.
    public var messageChangePublisher: AnyPublisher<EntityChange<ChatMessage>, Never> {
        basePublishers.messageChange.keepAlive(self)
    }

    /// A publisher emitting a new value every time the list of the replies of the message has changes.
    public var repliesChangesPublisher: AnyPublisher<[ListChange<ChatMessage>], Never> {
        basePublishers.repliesChanges.keepAlive(self)
    }

    /// A publisher emitting a new value every time a reaction changes.
    public var reactionsPublisher: AnyPublisher<[MessageReaction], Never> {
        basePublishers.reactions.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapper controller
        unowned let controller: MessageController

        /// A backing subject for `statePublisher`.
        let state: CurrentValueSubject<DataController.State, Never>

        /// A backing subject for `messageChangePublisher`.
        let messageChange: PassthroughSubject<EntityChange<ChatMessage>, Never> = .init()

        /// A backing subject for `repliesChangesPublisher`.
        let repliesChanges: PassthroughSubject<[ListChange<ChatMessage>], Never> = .init()

        /// A backing subject for `reactionsChangesPublisher`.
        let reactions: PassthroughSubject<[MessageReaction], Never> = .init()

        init(controller: MessageController) {
            self.controller = controller
            state = .init(controller.state)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension MessageController.BasePublishers: MessageControllerDelegate {
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state.send(state)
    }

    func messageController(
        _ controller: MessageController,
        didChangeMessage change: EntityChange<ChatMessage>
    ) {
        messageChange.send(change)
    }

    func messageController(
        _ controller: MessageController,
        didChangeReplies changes: [ListChange<ChatMessage>]
    ) {
        repliesChanges.send(changes)
    }

    func messageController(
        _ controller: MessageController,
        didChangeReactions reactions: [MessageReaction]
    ) {
        self.reactions.send(reactions)
    }
}
