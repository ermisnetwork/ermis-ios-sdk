//
// Copyright 2026 Ermis Inc.
//

import XCTest

@testable import ErmisChat
@testable import ErmisChatUI

@MainActor
final class ForwardingMessageViewControllerTests: XCTestCase {
    func testOrdinaryChannelIndexUsesSectionAndKeepsRowZero() throws {
        let biA = try makeChannel(id: "bi-a", name: "bi-a")
        let testE2ee = try makeChannel(id: "test-e2ee", name: "Test e2ee")
        let channels = [biA, testE2ee]

        let indexPath = ForwardingChannelListLayout.indexPath(
            for: testE2ee.cid,
            in: channels
        )

        let resolvedIndexPath = try XCTUnwrap(indexPath)
        XCTAssertEqual(resolvedIndexPath, IndexPath(row: 0, section: 1))
        XCTAssertEqual(
            ForwardingChannelListLayout.channel(at: resolvedIndexPath, in: channels)?.cid,
            testE2ee.cid
        )
        XCTAssertNil(
            ForwardingChannelListLayout.channel(
                at: IndexPath(row: 1, section: 0),
                in: channels
            )
        )
    }

    func testCidLookupDoesNotDependOnAReusedCellsPreviousIndexPath() throws {
        let biA = try makeChannel(id: "bi-a", name: "bi-a")
        let testE2ee = try makeChannel(id: "test-e2ee", name: "Test e2ee")

        let resolved = ForwardingChannelListLayout.channel(
            with: testE2ee.cid,
            in: [biA, testE2ee]
        )

        XCTAssertEqual(resolved?.cid, testE2ee.cid)
        XCTAssertEqual(resolved?.name, "Test e2ee")
    }

    func testTopicChannelUsesItsParentSectionAndTopicRow() throws {
        let first = try makeChannel(id: "first", name: "First")
        let topicA = try makeChannel(id: "topic-a", name: "Topic A", parentId: "parent")
        let topicB = try makeChannel(id: "topic-b", name: "Topic B", parentId: "parent")
        let parent = try makeChannel(
            id: "parent",
            name: "Parent",
            topics: [topicA, topicB]
        )

        let indexPath = ForwardingChannelListLayout.indexPath(
            for: topicB.cid,
            in: [first, parent]
        )

        let resolvedIndexPath = try XCTUnwrap(indexPath)
        XCTAssertEqual(resolvedIndexPath, IndexPath(row: 1, section: 1))
        XCTAssertEqual(
            ForwardingChannelListLayout.channel(at: resolvedIndexPath, in: [first, parent])?.cid,
            topicB.cid
        )
    }

    private func makeChannel(
        id: String,
        name: String,
        parentId: String? = nil,
        topics: [Channel]? = nil
    ) throws -> Channel {
        let projectId = "project"
        let parentCid = try parentId.map {
            try ChannelId(cid: "team:\(projectId):\($0)")
        }
        return Channel(
            cid: try ChannelId(cid: "team:\(projectId):\(id)"),
            parentCid: parentCid,
            name: name,
            description: nil,
            imageURL: nil,
            saveMessage: true,
            isHidden: false,
            isPublic: false,
            isPinned: false,
            topicEnabled: topics != nil,
            topics: { topics },
            mlsEnabled: true,
            previewMessage: { nil },
            underlyingContext: nil
        )
    }
}
