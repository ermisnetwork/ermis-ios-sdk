//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import SwiftUI

extension ConnectionController {
    /// A wrapper object that exposes the controller variables in the form of `ObservableObject` to be used in SwiftUI.
    public var observableObject: ObservableObject { .init(controller: self) }

    /// A wrapper object for `CurrentUserController` type which makes it possible to use the controller comfortably in SwiftUI.
    public class ObservableObject: SwiftUI.ObservableObject {
        /// The underlying controller. You can still access it and call methods on it.
        public let controller: ConnectionController

        /// The connection status.
        @Published public private(set) var connectionStatus: ConnectionStatus

        /// Creates a new `ObservableObject` wrapper with the provided controller instance.
        init(controller: ConnectionController) {
            self.controller = controller
            connectionStatus = controller.connectionStatus

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension ConnectionController.ObservableObject: ConnectionControllerDelegate {
    public func connectionController(
        _ controller: ConnectionController,
        didUpdateConnectionStatus status: ConnectionStatus
    ) {
        connectionStatus = status
    }
}
