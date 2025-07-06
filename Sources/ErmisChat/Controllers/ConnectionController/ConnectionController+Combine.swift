//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension ConnectionController {
    /// A publisher emitting a new value every time the connection status changes.
    public var connectionStatusPublisher: AnyPublisher<ConnectionStatus, Never> {
        basePublishers.connectionStatus.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapper controller
        unowned let controller: ConnectionController

        /// A backing subject for `connectionStatusPublisher`.
        let connectionStatus: CurrentValueSubject<ConnectionStatus, Never>

        init(controller: ConnectionController) {
            self.controller = controller
            connectionStatus = .init(controller.connectionStatus)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension ConnectionController.BasePublishers: ConnectionControllerDelegate {
    func connectionController(
        _ controller: ConnectionController,
        didUpdateConnectionStatus status: ConnectionStatus
    ) {
        connectionStatus.send(status)
    }
}
