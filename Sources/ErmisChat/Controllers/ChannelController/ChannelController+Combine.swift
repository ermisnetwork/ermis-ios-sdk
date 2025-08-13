//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension ChannelController {
    /// A publisher emitting a new value every time the state of the controller changes.
    public var statePublisher: AnyPublisher<DataController.State, Never> {
        basePublishers.state.keepAlive(self)
    }

    /// A publisher emitting a new value every time the channel changes.
    public var channelChangePublisher: AnyPublisher<EntityChange<Channel>, Never> {
        basePublishers.channelChange.keepAlive(self)
    }

    /// A publisher emitting a new value every time the list of the messages matching the query changes.
    public var messagesChangesPublisher: AnyPublisher<[ListChange<ChatMessage>], Never> {
        basePublishers.messagesChanges.keepAlive(self)
    }
    
    /// A publisher emitting a new value every time the list of the messages matching the query changes.
    public var topicsChangesPublisher: AnyPublisher<[ListChange<Channel>], Never> {
        basePublishers.topicChanges.keepAlive(self)
    }

    /// A publisher emitting a new value every time member event received.
    public var memberEventPublisher: AnyPublisher<MemberEvent, Never> {
        basePublishers.memberEvent.keepAlive(self)
    }

    /// A publisher emitting a new value every time typing users change.
    public var typingUsersPublisher: AnyPublisher<Set<ChatUser>, Never> {
        basePublishers.typingUsers.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapper controller
        unowned let controller: ChannelController

        /// A backing subject for `statePublisher`.
        let state: CurrentValueSubject<DataController.State, Never>

        /// A backing subject for `channelChangePublisher`.
        let channelChange: PassthroughSubject<EntityChange<Channel>, Never> = .init()

        /// A backing subject for `messagesChangesPublisher`.
        let messagesChanges: PassthroughSubject<[ListChange<ChatMessage>], Never> = .init()
        
        /// A backing subject for `messagesChangesPublisher`.
        let topicChanges: PassthroughSubject<[ListChange<Channel>], Never> = .init()

        /// A backing subject for `memberEventPublisher`.
        let memberEvent: PassthroughSubject<MemberEvent, Never> = .init()

        /// A backing subject for `typingUsersPublisher`.
        let typingUsers: PassthroughSubject<Set<ChatUser>, Never> = .init()

        init(controller: ChannelController) {
            self.controller = controller
            state = .init(controller.state)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension ChannelController.BasePublishers: ChannelControllerDelegate {
    func channelController(_ channelController: ChannelController, didUpdateTopic topics: [ListChange<Channel>]) {
        topicChanges.send(topics)
    }
    
    func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state.send(state)
    }

    func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    ) {
        channelChange.send(channel)
    }

    func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    ) {
        messagesChanges.send(changes)
    }

    func channelController(_ channelController: ChannelController, didReceiveMemberEvent event: MemberEvent) {
        memberEvent.send(event)
    }

    func channelController(
        _ channelController: ChannelController,
        didChangeTypingUsers typingUsers: Set<ChatUser>
    ) {
        self.typingUsers.send(typingUsers)
    }
}
