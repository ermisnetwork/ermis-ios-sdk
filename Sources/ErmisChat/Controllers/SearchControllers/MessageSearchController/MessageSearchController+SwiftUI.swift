//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import SwiftUI

extension MessageSearchController {
    /// A wrapper object that exposes the controller variables in the form of `ObservableObject` to be used in SwiftUI.
    public var observableObject: ObservableObject { .init(controller: self) }

    /// A wrapper object for `CurrentUserController` type which makes it possible to use the controller comfortably in SwiftUI.
    public class ObservableObject: SwiftUI.ObservableObject {
        /// The underlying controller. You can still access it and call methods on it.
        public let controller: MessageSearchController

        /// The current result of messages.
        @Published public private(set) var messages: LazyCachedMapCollection<ChatMessage> = []

        /// The current state of the controller.
        @Published public private(set) var state: DataController.State

        /// Creates a new `ObservableObject` wrapper with the provided controller instance.
        init(controller: MessageSearchController) {
            self.controller = controller
            state = self.controller.state

            controller.multicastDelegate.add(additionalDelegate: self)

            messages = controller.messages
        }
    }
}

extension MessageSearchController.ObservableObject: MessageSearchControllerDelegate {
    public func controller(_ controller: MessageSearchController, didChangeMessages changes: [ListChange<ChatMessage>]) {
        messages = controller.messages
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
    }
}
