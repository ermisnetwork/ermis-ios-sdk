//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import SwiftUI

extension ChannelWatcherListController {
    /// A wrapper object that exposes the controller variables in the form of `ObservableObject` to be used in SwiftUI.
    public var observableObject: ObservableObject { .init(controller: self) }

    /// A wrapper object for `ChannelWatcherListController` type which makes it possible to use the controller
    /// comfortably in SwiftUI.
    public class ObservableObject: SwiftUI.ObservableObject {
        /// The underlying controller. You can still access it and call methods on it.
        public let controller: ChannelWatcherListController

        /// The channel members.
        @Published public private(set) var watchers: LazyCachedMapCollection<ChatUser> = []

        /// The current state of the controller.
        @Published public private(set) var state: DataController.State

        /// Creates a new `ObservableObject` wrapper with the provided controller instance.
        init(controller: ChannelWatcherListController) {
            self.controller = controller
            state = controller.state

            controller.multicastDelegate.add(additionalDelegate: self)

            watchers = controller.watchers
        }
    }
}

extension ChannelWatcherListController.ObservableObject: ChannelWatcherListControllerDelegate {
    public func channelWatcherListController(
        _ controller: ChannelWatcherListController,
        didChangeWatchers changes: [ListChange<ChatUser>]
    ) {
        watchers = controller.watchers
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
    }
}
