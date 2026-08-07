import XCTest
@testable import ErmisChat

final class E2eeApplicationEpochActionTests: XCTestCase {
    private func applicationEnvelope(eventId: String, createdAt: String) throws -> E2eSyncEventEnvelope {
        let json = """
        {
          "event_id": "\(eventId)",
          "created_at": "\(createdAt)",
          "type": "application",
          "data": {
            "id": "message-\(eventId)",
            "type": "regular",
            "mls_ciphertext": "AA==",
            "mls_epoch": 7,
            "content_type": "text/plain",
            "created_at": "\(createdAt)"
          }
        }
        """
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(json.utf8))
    }

    func testEpochBeforeVerifiedJoinIsHistoricalEvenWithoutLoadedGroup() {
        XCTAssertEqual(
            E2eeApplicationEpochAction.resolve(
                messageEpoch: 4,
                firstDecryptableEpoch: 5,
                hasGroup: false
            ),
            .preJoinHistorical
        )
    }

    func testSameOrLaterEpochWaitsForMissingGroup() {
        XCTAssertEqual(
            E2eeApplicationEpochAction.resolve(
                messageEpoch: 5,
                firstDecryptableEpoch: 5,
                hasGroup: false
            ),
            .pendingGroup
        )
    }

    func testSameOrLaterEpochDecryptsWhenGroupExists() {
        XCTAssertEqual(
            E2eeApplicationEpochAction.resolve(
                messageEpoch: 6,
                firstDecryptableEpoch: 5,
                hasGroup: true
            ),
            .decrypt
        )
    }

    func testMissingVerifiedJoinEpochIsNeverGuessedFromCurrentGroup() {
        XCTAssertEqual(
            E2eeApplicationEpochAction.resolve(
                messageEpoch: 1,
                firstDecryptableEpoch: nil,
                hasGroup: true
            ),
            .decrypt
        )
    }

    func testMergedReceiptBuffersSameEpochApplicationUntilExactCommitBoundary() throws {
        let event = try applicationEnvelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-07T10:00:00.000000Z"
        )
        XCTAssertEqual(
            E2eeApplicationEpochAction.resolve(
                envelope: event,
                messageEpoch: 7,
                firstDecryptableEpoch: 7,
                joinBoundary: nil,
                awaitingExternalCommitBoundary: true,
                hasGroup: true
            ),
            .pendingGroup
        )
    }

    func testEventBeforeExactBoundaryIsHistoricalEvenAtSameEpoch() throws {
        let historical = try applicationEnvelope(
            eventId: "11111111-1111-4111-8111-111111111111",
            createdAt: "2026-08-07T10:00:00.000000Z"
        )
        let boundary = try applicationEnvelope(
            eventId: "22222222-2222-4222-8222-222222222222",
            createdAt: "2026-08-07T10:00:01.000000Z"
        )
        XCTAssertEqual(
            E2eeApplicationEpochAction.resolve(
                envelope: historical,
                messageEpoch: 7,
                firstDecryptableEpoch: 7,
                joinBoundary: boundary,
                awaitingExternalCommitBoundary: false,
                hasGroup: true
            ),
            .preJoinHistorical
        )
    }

    func testBellboyMessagePinUsesOuterScopeCidAndSender() throws {
        let json = """
        {
          "event_id": "33333333-3333-4333-8333-333333333333",
          "created_at": "2026-08-07T10:00:00.000000Z",
          "type": "message_pin",
          "data": {
            "action": "pin",
            "sender": {"id": "sender", "project_id": "project"},
            "created_at": "2026-08-07T10:00:00.000000Z",
            "message": {
              "id": "message-1",
              "user": {"id": "sender", "project_id": "project"},
              "created_at": "2026-08-07T10:00:00.000000Z"
            }
          }
        }
        """
        let envelope = try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(json.utf8))
        guard case .messagePin(let pin) = envelope.event else {
            return XCTFail("Expected typed message_pin payload")
        }
        XCTAssertEqual(pin.action, "pin")
        XCTAssertEqual(pin.message.id, "message-1")
        XCTAssertEqual(pin.sender?.id, "sender")
    }
}
