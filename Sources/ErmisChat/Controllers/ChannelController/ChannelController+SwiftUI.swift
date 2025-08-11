//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import SwiftUI

extension ChannelController {
    /// A wrapper object that exposes the controller variables in the form of `ObservableObject` to be used in SwiftUI.
    public var observableObject: ObservableObject { .init(controller: self) }

    /// A wrapper object for `ChannelListController` type which makes it possible to use the controller comfortably in SwiftUI.
    public class ObservableObject: SwiftUI.ObservableObject {
        /// The underlying controller. You can still access it and call methods on it.
        public let controller: ChannelController

        /// The channel matching the ChannelId.
        @Published public private(set) var channel: Channel?

        /// The messages related to the channel.
        @Published public private(set) var messages: LazyCachedMapCollection<ChatMessage> = []
        
        @Published public private(set) var topics: LazyCachedMapCollection<Channel> = []

        /// The current state of the Controller.
        @Published public private(set) var state: DataController.State

        /// The typing users related to the channel.
        @Published public private(set) var typingUsers: Set<ChatUser> = []

        /// Creates a new `ObservableObject` wrapper with the provided controller instance.
        init(controller: ChannelController) {
            self.controller = controller
            state = controller.state

            controller.multicastDelegate.add(additionalDelegate: self)

            channel = controller.channel
            messages = controller.messages
            typingUsers = controller.channel?.currentlyTypingUsers ?? []
        }
    }
}

extension ChannelController.ObservableObject: ChannelControllerDelegate {
    public func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    ) {
        self.channel = channelController.channel
    }
    
    public func channelController(_ channelController: ChannelController, didUpdateTopic topics: [ListChange<Channel>]) {
        self.topics = channelController.topics
    }

    public func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    ) {
        messages = channelController.messages
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
    }

    public func channelController(
        _ channelController: ChannelController,
        didChangeTypingUsers typingUsers: Set<ChatUser>
    ) {
        self.typingUsers = typingUsers
    }
}
