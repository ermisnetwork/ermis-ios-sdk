//
// Copyright 2025 Ermis Inc.
//

import Foundation

public protocol ConnectionEvent: Event {
    var connectionId: String { get }
}

public class HealthCheckEvent: ConnectionEvent, EventDTO {
    public let connectionId: String
    public let projectId: String?
    let keyPackagesRemaining: Int?
    var currentUser: CurrentUserPayload?
    let payload: EventPayload

    init(from eventResponse: EventPayload) throws {
        // Current Bellboy `health.check` payloads intentionally do not contain a
        // `connection_id`. Keep accepting it for older deployments, while allowing the
        // WebSocket client to use this opaque fallback as its connection-generation token.
        self.connectionId = eventResponse.connectionId ?? UUID().uuidString
        self.currentUser = eventResponse.currentUser
        self.projectId = eventResponse.projectId
        self.keyPackagesRemaining = eventResponse.currentUser?.keyPackagesRemaining
        payload = eventResponse
    }

    init(connectionId: String) {
        self.connectionId = connectionId
        self.projectId = nil
        self.keyPackagesRemaining = nil
        payload = EventPayload(
            eventType: .healthCheck,
            connectionId: connectionId,
            cid: nil,
            currentUser: nil,
            channel: nil
        )
    }

    func toDomainEvent(session: any DatabaseSession) -> (any Event)? {
        if let currentUser {
            try? session.saveCurrentUser(payload: currentUser,
                                         projectId: projectId ?? currentUser.projectId)
        }
        return self
    }
}

/// Emitted when `Client` changes it's connection status. You can listen to this event and indicate the different connection
/// states in the UI (banners like "Offline", "Reconnecting"", etc.).
public struct ConnectionStatusUpdated: Event {
    /// The current connection status of `Client`
    public let connectionStatus: ConnectionStatus

    // Underlying WebSocketConnectionState
    let webSocketConnectionState: WebSocketConnectionState

    init(webSocketConnectionState: WebSocketConnectionState) {
        connectionStatus = .init(webSocketConnectionState: webSocketConnectionState)
        self.webSocketConnectionState = webSocketConnectionState
    }
}
