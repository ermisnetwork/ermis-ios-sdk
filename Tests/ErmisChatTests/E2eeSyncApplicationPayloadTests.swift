import XCTest
@testable import ErmisChat

final class E2eeSyncApplicationPayloadTests: XCTestCase {
    func testEncryptedApplicationVariantsRemainTypedApplicationEvents() throws {
        for messageType in ["regular", "reply", "signal", "sticker", "poll", "future_type"] {
            let envelope = try applicationEnvelope(type: messageType, ciphertext: "AA==")

            guard case .application(let application) = envelope.event else {
                return XCTFail("Expected application event for message type \(messageType)")
            }
            XCTAssertEqual(application.type, messageType)
            XCTAssertFalse(application.isSystemMessage)
            XCTAssertEqual(application.mlsCiphertext, [0])
        }
    }

    func testSystemApplicationRemainsTypedWithoutCiphertext() throws {
        let envelope = try applicationEnvelope(type: "system", ciphertext: nil)

        guard case .application(let application) = envelope.event else {
            return XCTFail("Expected system application event")
        }
        XCTAssertTrue(application.isSystemMessage)
        XCTAssertNil(application.mlsCiphertext)
    }

    func testMissingMessageTypeDefaultsToRegularApplication() throws {
        let envelope = try applicationEnvelope(type: nil, ciphertext: "AA==")

        guard case .application(let application) = envelope.event else {
            return XCTFail("Expected default application event")
        }
        XCTAssertEqual(application.type, MessageType.regular.rawValue)
        XCTAssertFalse(application.isSystemMessage)
    }

    private func applicationEnvelope(
        type: String?,
        ciphertext: String?
    ) throws -> E2eSyncEventEnvelope {
        var data: [String: Any] = [
            "id": "message-1",
            "cid": "team:channel-1",
            "content_type": ciphertext == nil ? "standard" : "mls",
            "created_at": "2026-08-07T05:07:52.000000Z"
        ]
        data["type"] = type
        data["mls_ciphertext"] = ciphertext

        let json: [String: Any] = [
            "event_id": "d0f0a0ef-71f7-4a2e-b2fa-1edb2fb55b6a",
            "created_at": "2026-08-07T05:07:52.000000Z",
            "type": "application",
            "data": data
        ]
        let encoded = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: encoded)
    }
}
