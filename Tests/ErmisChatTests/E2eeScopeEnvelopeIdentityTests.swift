import Foundation
import XCTest
#if !E2EE_ENVELOPE_IDENTITY_STANDALONE
@testable import ErmisChat
#endif

final class E2eeScopeEnvelopeIdentityTests: XCTestCase {
    private let messageTime = "2026-11-05T04:22:14.251311Z"
    private let eventTime = "2026-11-05T04:22:14.251325Z"
    private let uuid = "ac73b0ed-1111-4111-8111-111111111111"

    private func envelope(time: String? = nil, kind: String = "application", payload: [String: RawJSON] = [:], root: [String: RawJSON] = [:]) throws -> Data {
        var data: [String: RawJSON] = ["id": .string(uuid), "created_at": .string(messageTime), "mls_ciphertext": "AAEC", "mls_epoch": 66, "cid": "team:project:group", "user": ["id": "sender"], "aad": "bound"]
        data.merge(payload) { _, new in new }
        var object: [String: RawJSON] = ["event_id": .string(uuid), "created_at": .string(time ?? messageTime), "type": .string(kind), "data": .dictionary(data)]
        object.merge(root) { _, new in new }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(RawJSON.dictionary(object))
    }

    func testExactEnvelopeRemainsIdempotent() throws {
        let value = try envelope()
        XCTAssertTrue(E2eeScopeEnvelopeIdentity.matches(value, value))
    }

    func testRealDualIndexMicrosecondDifferenceMatchesInBothOrders() throws {
        let message = try envelope()
        let wrapper = try envelope(time: eventTime)
        XCTAssertNotEqual(message, wrapper)
        XCTAssertTrue(E2eeScopeEnvelopeIdentity.matches(message, wrapper))
        XCTAssertTrue(E2eeScopeEnvelopeIdentity.matches(wrapper, message))
    }

    func testNonApplicationTypesRetainStrictClockIdentity() throws {
        for kind in ["protocol", "metadata", "future_event"] {
            XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(kind: kind), try envelope(time: eventTime, kind: kind)))
        }
    }

    func testCiphertextAndAllBindingFieldsRemainImmutable() throws {
        let mutations: [[String: RawJSON]] = [
            ["mls_ciphertext": "AAED"], ["mls_epoch": 67], ["aad": "different"],
            ["cid": "team:project:other"], ["user": ["id": "other"]],
            ["id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"],
            ["created_at": .string(eventTime)], ["future_payload": true]
        ]
        for mutation in mutations {
            XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(), try envelope(time: eventTime, payload: mutation)))
        }
    }

    func testRootIdentityRoutingAndUnknownFieldsRemainImmutable() throws {
        for mutation: [String: RawJSON] in [["event_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"], ["cid": "other"], ["future_field": true]] {
            XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(), try envelope(time: eventTime, root: mutation)))
        }
    }

    func testBothOuterClocksDetachedFromMessageAreRejected() throws {
        XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(time: eventTime), try envelope(time: "2026-11-05T04:22:14.251326Z")))
    }

    func testClockOneMicrosecondBeforeMessageIsRejected() throws {
        XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(), try envelope(time: "2026-11-05T04:22:14.251310Z")))
    }

    func testNanosecondOrderingIsNotRoundedByDate() throws {
        let inner: [String: RawJSON] = ["created_at": "2026-11-05T04:22:14.251311123Z"]
        let message = try envelope(time: "2026-11-05T04:22:14.251311123Z", payload: inner)
        XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(message, try envelope(time: "2026-11-05T04:22:14.251311122Z", payload: inner)))
        XCTAssertTrue(E2eeScopeEnvelopeIdentity.matches(message, try envelope(time: "2026-11-05T04:22:14.251311124Z", payload: inner)))
    }

    func testVariablePrecisionUTCClocksCompareExactly() throws {
        let inner: [String: RawJSON] = ["created_at": "2026-11-05T04:22:14Z"]
        XCTAssertTrue(E2eeScopeEnvelopeIdentity.matches(try envelope(time: "2026-11-05T04:22:14Z", payload: inner), try envelope(time: "2026-11-05T04:22:14.000001Z", payload: inner)))
    }

    func testInvalidAndNonUTCClocksAreRejected() throws {
        for time in ["invalid", "2026-11-05T04:22:14.251325+00:00", "2026-11-05T04:22:14.2513250000Z"] {
            XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(), try envelope(time: time)))
        }
    }

    func testNonUUIDAndUnboundMessageIdsAreRejected() throws {
        let root: [String: RawJSON] = ["event_id": "not-a-uuid"]
        let payload: [String: RawJSON] = ["id": "not-a-uuid"]
        XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(payload: payload, root: root), try envelope(time: eventTime, payload: payload, root: root)))
        XCTAssertFalse(E2eeScopeEnvelopeIdentity.matches(try envelope(payload: ["id": "other"]), try envelope(time: eventTime, payload: ["id": "other"])))
    }
}
