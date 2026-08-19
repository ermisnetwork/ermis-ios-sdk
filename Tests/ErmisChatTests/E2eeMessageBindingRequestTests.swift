//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeMessageBindingRequestTests: XCTestCase {
    func testNonForwardBodyOmitsLegacyEmptyForwardMetadata() throws {
        let request = MessageRequestBody(
            id: UUID().uuidString,
            user: UserRequestBody(id: "user", name: nil, imageURL: nil),
            text: "",
            forwardCid: "",
            forwardMessageId: "",
            forwardParentCid: ""
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.default.encode(request))
                as? [String: Any]
        )

        XCTAssertNil(request.forwardCid)
        XCTAssertNil(request.forwardMessageId)
        XCTAssertNil(request.forwardParentCid)
        XCTAssertFalse(request.requiresE2eeAuthenticatedSendLane)
        XCTAssertNil(object["forward_cid"])
        XCTAssertNil(object["forward_message_id"])
        XCTAssertNil(object["forward_parent_cid"])
    }

    func testAttachmentEnvelopeDoesNotEncodeLegacyEmptyForwardCid() throws {
        let attachmentId = "00000000-0000-4000-8000-000000000001"
        var request = MessageRequestBody(
            id: UUID().uuidString,
            user: UserRequestBody(id: "user", name: nil, imageURL: nil),
            text: "",
            forwardCid: ""
        )

        try request.bindE2eeAuthenticatedEnvelope(
            destinationCid: ChannelId(type: .team, id: "destination"),
            groupId: "team:destination",
            attachmentIds: [attachmentId]
        )
        let aad = try XCTUnwrap(request.authenticatedAAD())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.default.encode(request))
                as? [String: Any]
        )

        XCTAssertNil(aad.forwardCid)
        XCTAssertEqual(aad.attachmentIds, [attachmentId])
        XCTAssertNil(object["forward_cid"])
        XCTAssertEqual(object["e2ee_attachment_ids"] as? [String], [attachmentId])
    }

    func testAttachmentEnvelopeAndAADUseSameCanonicalIdSet() throws {
        let messageId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let first = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let second = "00000000-0000-4000-8000-000000000001"
        let cid = ChannelId(type: .team, id: "destination")
        var request = MessageRequestBody(
            id: messageId,
            user: UserRequestBody(id: "user", name: nil, imageURL: nil),
            text: "plaintext remains inside MLS only"
        )

        try request.bindE2eeAuthenticatedEnvelope(
            destinationCid: cid,
            groupId: "team:destination",
            attachmentIds: [first, second]
        )
        let aad = try XCTUnwrap(request.authenticatedAAD())
        request.bindE2eeNetworkIntent(ciphertext: [1, 2, 3], epoch: 9)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.default.encode(request))
                as? [String: Any]
        )

        XCTAssertEqual(request.e2eeAttachmentIds, [second, first])
        XCTAssertEqual(request.cid, cid)
        XCTAssertEqual(object["e2ee_attachment_ids"] as? [String], [second, first])
        XCTAssertEqual(object["e2ee_group_id"] as? String, "team:destination")
        XCTAssertEqual(object["text"] as? String, "")
        XCTAssertEqual(
            try aad.encoded(),
            try E2eeMessageAADV1(
                cid: cid.rawValue,
                e2eeGroupId: "team:destination",
                messageId: messageId,
                attachmentIds: [second, first]
            ).encoded()
        )
    }

    func testTextOnlyForwardStillRequiresAADWithEmptyAttachmentList() throws {
        let cid = ChannelId(type: .team, id: "destination")
        var request = MessageRequestBody(
            id: UUID().uuidString,
            user: UserRequestBody(id: "user", name: nil, imageURL: nil),
            text: "forwarded text",
            cid: cid,
            forwardCid: "team:source",
            forwardMessageId: UUID().uuidString,
            forwardParentCid: "team:source-parent"
        )
        try request.bindE2eeAuthenticatedEnvelope(
            destinationCid: cid,
            groupId: "team:destination",
            attachmentIds: [],
            forwardParentCid: "team:source-parent"
        )

        let aad = try XCTUnwrap(request.authenticatedAAD())

        XCTAssertTrue(aad.isRequired)
        XCTAssertTrue(aad.attachmentIds.isEmpty)
        XCTAssertEqual(aad.forwardCid, "team:source")
        XCTAssertEqual(aad.forwardParentCid, "team:source-parent")
    }

    func testAuthenticatedEnvelopeFailsClosedWithoutGroupIdOrWithDuplicateIds() throws {
        var request = MessageRequestBody(
            id: UUID().uuidString,
            user: UserRequestBody(id: "user", name: nil, imageURL: nil),
            text: "payload",
            cid: ChannelId(type: .team, id: "destination"),
            e2eeAttachmentIds: [UUID().uuidString]
        )

        XCTAssertThrowsError(try request.authenticatedAAD()) { error in
            XCTAssertEqual(error as? E2eeMessageAADError, .missingE2eeGroupId)
        }

        let duplicate = UUID().uuidString
        XCTAssertThrowsError(
            try request.bindE2eeAuthenticatedEnvelope(
                destinationCid: ChannelId(type: .team, id: "destination"),
                groupId: "team:destination",
                attachmentIds: [duplicate, duplicate]
            )
        ) { error in
            XCTAssertEqual(error as? E2eeMessageAADError, .duplicateAttachmentId(duplicate))
        }
    }
}
