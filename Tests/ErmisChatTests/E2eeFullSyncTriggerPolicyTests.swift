import XCTest
@testable import ErmisChat

final class E2eeFullSyncTriggerPolicyTests: XCTestCase {
    func testHealthCheckDoesNotTriggerFullSync() {
        let healthCheck = HealthCheckEvent(connectionId: "heartbeat")

        XCTAssertFalse(E2eeFullSyncTriggerPolicy.shouldRunFullSync(for: healthCheck))
    }

    func testConnectedTransitionTriggersFullSync() {
        let connected = ConnectionStatusUpdated(
            webSocketConnectionState: .connected(connectionId: "connection")
        )

        XCTAssertTrue(E2eeFullSyncTriggerPolicy.shouldRunFullSync(for: connected))
    }

    func testNonConnectedTransitionsDoNotTriggerFullSync() {
        let states: [WebSocketConnectionState] = [
            .initialized,
            .connecting,
            .waitingForConnectionId,
            .disconnecting(source: .userInitiated),
            .disconnected(source: .systemInitiated)
        ]

        for state in states {
            let event = ConnectionStatusUpdated(webSocketConnectionState: state)
            XCTAssertFalse(E2eeFullSyncTriggerPolicy.shouldRunFullSync(for: event))
        }
    }
}
