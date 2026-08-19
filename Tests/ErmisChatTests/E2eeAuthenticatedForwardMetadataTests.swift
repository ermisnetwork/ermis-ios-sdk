//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import XCTest

final class E2eeAuthenticatedForwardMetadataTests: XCTestCase {
    func testAADDecodeRoundTripPreservesForwardAndCanonicalAttachments() throws {
        let value = E2eeMessageAADV1(
            cid: "team:destination",
            e2eeGroupId: "team:destination",
            messageId: "11111111-1111-4111-8111-111111111111",
            forwardCid: "team:source",
            forwardMessageId: "source-message",
            forwardParentCid: "team:source-parent",
            attachmentIds: [
                "ffffffff-ffff-4fff-8fff-ffffffffffff",
                "00000000-0000-4000-8000-000000000001"
            ]
        )
        let encoded = try value.encoded()
        let decoded = try E2eeMessageAADV1.decoded(from: encoded)

        XCTAssertEqual(decoded.cid, value.cid)
        XCTAssertEqual(decoded.forwardCid, value.forwardCid)
        XCTAssertEqual(decoded.forwardMessageId, value.forwardMessageId)
        XCTAssertEqual(decoded.forwardParentCid, value.forwardParentCid)
        XCTAssertEqual(
            decoded.attachmentIds,
            try E2eeMessageAADV1.canonicalAttachmentIds(value.attachmentIds)
        )
    }

    func testAADDecoderRejectsTrailingAndNonCanonicalBytes() throws {
        let value = E2eeMessageAADV1(
            cid: "team:destination",
            e2eeGroupId: "team:destination",
            messageId: "11111111-1111-4111-8111-111111111111",
            attachmentIds: [
                "ffffffff-ffff-4fff-8fff-ffffffffffff",
                "00000000-0000-4000-8000-000000000001"
            ]
        )
        var trailing = try value.encoded()
        trailing.append(0)
        XCTAssertThrowsError(try E2eeMessageAADV1.decoded(from: trailing))

        let ordered = E2eeMessageAADV1(
            cid: value.cid,
            e2eeGroupId: value.e2eeGroupId,
            messageId: value.messageId,
            attachmentIds: Array(value.attachmentIds.reversed())
        )
        XCTAssertEqual(try ordered.encoded(), try value.encoded())
    }

    func testVersionTwoCachePersistsAuthenticatedForwardMetadata() throws {
        let metadata = E2eeAuthenticatedMessageMetadata(
            forwardCid: "team:source",
            forwardMessageId: "source-message",
            forwardParentCid: "team:parent",
            attachmentIds: ["00000000-0000-4000-8000-000000000001"]
        )
        let envelope = E2eCachedAttachments(authenticatedMetadata: metadata)
        let data = try JSONEncoder.default.encode(envelope)
        let decoded = try E2eCachedAttachments.decodeCompatible(from: data)
        XCTAssertEqual(decoded.authenticatedMetadata, metadata)
        XCTAssertEqual(decoded.version, 2)
    }

    func testVersionOneCacheRemainsReadable() throws {
        let data = Data(#"{"version":1,"legacy":[],"e2ee":[]}"#.utf8)
        let decoded = try E2eCachedAttachments.decodeCompatible(from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.authenticatedMetadata)
    }
}
