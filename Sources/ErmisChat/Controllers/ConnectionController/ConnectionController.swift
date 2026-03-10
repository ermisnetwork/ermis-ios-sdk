//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import ErmisShared

public extension ErmisClient {
    /// Creates a new `ConnectionController` instance.
    ///
    /// - Returns: A new instance of `ConnectionController`.
    ///
    func connectionController() -> ConnectionController {
        .init(connectionRepository: connectionRepository, webSocketClient: webSocketClient, client: self)
    }
}

/// `ConnectionController` is a controller class which allows to explicitly
/// connect/disconnect the `ErmisClient` and observe connection events.
public class ConnectionController: Controller, DelegateCallable, DataStoreProvider {
    public var callbackQueue: DispatchQueue = .main

    var _basePublishers: Any?
    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    var basePublishers: BasePublishers {
        if let value = _basePublishers as? BasePublishers {
            return value
        }
        _basePublishers = BasePublishers(controller: self)
        return _basePublishers as? BasePublishers ?? .init(controller: self)
    }

    /// The current connection status of the client.
    ///
    /// To observe changes of the connection status, set your class as a delegate of this controller or use the provided
    /// `Combine` publishers.
    ///
    public var connectionStatus: ConnectionStatus {
        client.connectionStatus
    }

    /// The connection event observer for the connection status updates.
    private var connectionEventObserver: ConnectionEventObserver?

    /// A type-erased delegate.
    var multicastDelegate: MulticastDelegate<ConnectionControllerDelegate> = .init()

    private let connectionRepository: ConnectionRepository
    private let webSocketClient: WebSocketClient?

    /// The `ErmisClient` instance this controller belongs to.
    public let client: ErmisClient

    /// Creates a new `ChatConnectionControllerGeneric`.
    ///
    /// - Parameters:
    ///   - client: The `Client` instance this controller belongs to.
    ///   - environment: The source of internal dependencies
    ///
    init(connectionRepository: ConnectionRepository, webSocketClient: WebSocketClient?, client: ErmisClient) {
        self.connectionRepository = connectionRepository
        self.webSocketClient = webSocketClient
        self.client = client
        connectionEventObserver = setupObserver()
    }

    private func setupObserver() -> ConnectionEventObserver? {
        guard let webSocketClient = webSocketClient else { return nil }
        let observer = ConnectionEventObserver(
            notificationCenter: webSocketClient.eventNotificationCenter
        ) { [weak self] status in
            self?.delegateCallback { [weak self] in
                guard let self = self else {
                    log.warning("Callback called while self is nil")
                    return
                }
                $0.connectionController(self, didUpdateConnectionStatus: status.connectionStatus)
            }
        }
        return observer
    }
}

public extension ConnectionController {
    /// Connects the chat client the controller represents to the chat servers.
    ///
    /// When the connection is established, `ErmisClient` starts receiving chat updates.
    ///
    /// - Parameter completion: Called when the connection is established. If the connection fails, the completion is
    /// called with an error.
    ///
    func connect(completion: ((Error?) -> Void)? = nil) {
        connectionRepository.connect { [weak self] error in
            self?.callback {
                completion?(error)
            }
        }
    }

    /// Disconnects the chat client the controller represents from the chat servers.
    /// No further updates from the servers are received.
    func disconnect() {
        connectionRepository.disconnect(source: .userInitiated) {
            log.info("The `ErmisClient` has been disconnected.", subsystems: .webSocket)
        }
    }
}

// MARK: - Delegates

/// `ConnectionController` uses this protocol to communicate changes to its delegate.
@preconcurrency
public protocol ConnectionControllerDelegate: AnyObject {
    /// The controller observed a change in connection status.
    func connectionController(_ controller: ConnectionController, didUpdateConnectionStatus status: ConnectionStatus)
}

public extension ConnectionControllerDelegate {
    func connectionController(_ controller: ConnectionController, didUpdateConnectionStatus status: ConnectionStatus) {}
}

public extension ConnectionController {
    /// Set the delegate of `ConnectionController` to observe the changes in the system.
    var delegate: ConnectionControllerDelegate? {
        get { multicastDelegate.mainDelegate }
        set { multicastDelegate.set(mainDelegate: newValue) }
    }
}

/// A connection event observer to handle `ConnectionStatusUpdated` events.
private class ConnectionEventObserver: EventObserver {
    init(
        notificationCenter: NotificationCenter,
        filter: ((ConnectionStatusUpdated) -> Bool)? = nil,
        callback: @escaping (ConnectionStatusUpdated) -> Void
    ) {
        super.init(notificationCenter: notificationCenter, transform: { $0 as? ConnectionStatusUpdated }) {
            guard filter == nil || filter?($0) == true else { return }
            callback($0)
        }
    }
}
