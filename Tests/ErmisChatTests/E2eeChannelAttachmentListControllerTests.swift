//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

@MainActor
final class E2eeChannelAttachmentListControllerTests: XCTestCase {
    private let cid = ChannelId(type: .messaging, id: "channel-info-controller")

    func testPaginationPreservesServerOrderAndDeduplicatesItems() async throws {
        let cursor = E2eeChannelAttachmentListCursor(createdAt: "2026-08-17T10:00:00Z", attachmentId: "a2")
        var requestedCursors: [E2eeChannelAttachmentListCursor?] = []
        var requestedCids: [ChannelId] = []
        var requestedLimits: [Int] = []
        let first = makeItem(id: "a1", createdAt: Date(timeIntervalSince1970: 3))
        let duplicate = makeItem(id: "a1", createdAt: Date(timeIntervalSince1970: 2))
        let second = makeItem(id: "a2", createdAt: Date(timeIntervalSince1970: 1))
        var pages = [
            E2eeChannelAttachmentListPage(
                items: [first],
                nextCursor: cursor,
                hasMore: true,
                unavailableCount: 1
            ),
            E2eeChannelAttachmentListPage(
                items: [duplicate, second],
                nextCursor: nil,
                hasMore: false,
                unavailableCount: 2
            )
        ]
        let controller = E2eeChannelAttachmentListController(cid: cid) { requestCid, limit, requestCursor in
            requestedCids.append(requestCid)
            requestedLimits.append(limit)
            requestedCursors.append(requestCursor)
            return pages.removeFirst()
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.phase == .loaded }
        controller.loadNextPage()
        try await waitUntil { controller.snapshot.items.count == 2 }

        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["a1", "a2"])
        XCTAssertEqual(requestedCids, [cid, cid])
        XCTAssertEqual(requestedLimits, [50, 50])
        XCTAssertEqual(requestedCursors.count, 2)
        XCTAssertNil(requestedCursors[0])
        XCTAssertEqual(requestedCursors[1], cursor)
        XCTAssertEqual(controller.snapshot.unavailableCount, 3)
        XCTAssertFalse(controller.snapshot.hasMore)
    }

    func testPageSizeIsClampedToBellboyMaximum() async throws {
        var requestedLimit: Int?
        let controller = E2eeChannelAttachmentListController(cid: cid, pageSize: 999) { _, limit, _ in
            requestedLimit = limit
            return E2eeChannelAttachmentListPage(
                items: [],
                nextCursor: nil,
                hasMore: false,
                unavailableCount: 0
            )
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.phase == .loaded }

        XCTAssertEqual(requestedLimit, 100)
    }

    func testSameNextCursorStopsPaginationLoop() async throws {
        let cursor = E2eeChannelAttachmentListCursor(createdAt: "2026-08-17T10:00:00Z", attachmentId: "a1")
        var callCount = 0
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, _ in
            callCount += 1
            return E2eeChannelAttachmentListPage(
                items: [],
                nextCursor: cursor,
                hasMore: true,
                unavailableCount: 0
            )
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.phase == .loaded }
        controller.loadNextPage()
        try await waitUntil { callCount == 2 && controller.snapshot.phase == .loaded }

        XCTAssertFalse(controller.snapshot.hasMore)
        controller.loadNextPage()
        await Task.yield()
        XCTAssertEqual(callCount, 2)
    }

    func testRetryKeepsLoadedItemsAndRetriesSameCursor() async throws {
        let cursor = E2eeChannelAttachmentListCursor(createdAt: "2026-08-17T10:00:00Z", attachmentId: "a1")
        var callCount = 0
        let first = makeItem(id: "a1", createdAt: Date(timeIntervalSince1970: 2))
        let second = makeItem(id: "a2", createdAt: Date(timeIntervalSince1970: 1))
        let controller = E2eeChannelAttachmentListController(
            cid: cid,
            failureClassifier: { _ in .retryable }
        ) { _, _, requestCursor in
            callCount += 1
            if callCount == 1 {
                return E2eeChannelAttachmentListPage(
                    items: [first],
                    nextCursor: cursor,
                    hasMore: true,
                    unavailableCount: 0
                )
            }
            if callCount == 2 {
                throw TestError.requestFailed
            }
            XCTAssertEqual(requestCursor, cursor)
            return E2eeChannelAttachmentListPage(
                items: [second],
                nextCursor: nil,
                hasMore: false,
                unavailableCount: 0
            )
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.items.count == 1 }
        controller.loadNextPage()
        try await waitUntil { controller.snapshot.phase == .failed }
        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["a1"])
        XCTAssertEqual(controller.snapshot.failureKind, .retryable)
        XCTAssertEqual(
            controller.snapshot.tabPresentationState(filteredItemCount: 1),
            .retryableFailure
        )
        XCTAssertEqual(
            controller.snapshot.tabPresentationState(filteredItemCount: 0),
            .retryableFailure
        )

        controller.retry()
        try await waitUntil { controller.snapshot.items.count == 2 }
        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["a1", "a2"])
        XCTAssertNil(controller.snapshot.failureKind)
    }

    func testTerminalFailurePreservesRowsAndDoesNotRetry() async throws {
        var callCount = 0
        let first = makeItem(id: "a1", createdAt: Date(timeIntervalSince1970: 1))
        let cursor = E2eeChannelAttachmentListCursor(
            createdAt: "2026-08-17T10:00:00Z",
            attachmentId: "a1"
        )
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, _ in
            callCount += 1
            if callCount == 1 {
                return E2eeChannelAttachmentListPage(
                    items: [first],
                    nextCursor: cursor,
                    hasMore: true,
                    unavailableCount: 0
                )
            }
            throw TestError.requestFailed
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.items.count == 1 }
        controller.loadNextPage()
        try await waitUntil { controller.snapshot.phase == .failed }

        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["a1"])
        XCTAssertEqual(controller.snapshot.failureKind, .terminal)

        controller.retry()
        await Task.yield()

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(controller.snapshot.phase, .failed)
        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["a1"])
    }

    func testNetworkFailureIsRetryable() async throws {
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, _ in
            throw URLError(.timedOut)
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.phase == .failed }

        XCTAssertEqual(controller.snapshot.failureKind, .retryable)
        XCTAssertTrue(controller.snapshot.items.isEmpty)
    }

    func testTabPresentationStateIsDerivedIndependentlyFromFilteredRows() async throws {
        let item = makeItem(id: "media", createdAt: Date(timeIntervalSince1970: 1))
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, _ in
            E2eeChannelAttachmentListPage(
                items: [item],
                nextCursor: nil,
                hasMore: false,
                unavailableCount: 0
            )
        }

        XCTAssertEqual(
            controller.snapshot.tabPresentationState(filteredItemCount: 0),
            .loading
        )

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.phase == .loaded }

        // The media tab has one row while file/voice tabs may be empty. They derive their own
        // state from the same immutable snapshot without resetting the shared items.
        XCTAssertEqual(
            controller.snapshot.tabPresentationState(filteredItemCount: 1),
            .hidden
        )
        XCTAssertEqual(
            controller.snapshot.tabPresentationState(filteredItemCount: 0),
            .empty
        )
        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["media"])
    }

    func testRefreshIgnoresCancelledGenerationResult() async throws {
        var callCount = 0
        let stale = makeItem(id: "stale", createdAt: Date(timeIntervalSince1970: 1))
        let fresh = makeItem(id: "fresh", createdAt: Date(timeIntervalSince1970: 2))
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, _ in
            callCount += 1
            if callCount == 1 {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    // Simulate a transport that still produces a response after cancellation.
                }
                return E2eeChannelAttachmentListPage(
                    items: [stale],
                    nextCursor: nil,
                    hasMore: false,
                    unavailableCount: 0
                )
            }
            return E2eeChannelAttachmentListPage(
                items: [fresh],
                nextCursor: nil,
                hasMore: false,
                unavailableCount: 0
            )
        }

        controller.startIfNeeded()
        try await waitUntil { callCount == 1 }
        controller.refresh()
        try await waitUntil { controller.snapshot.items.first?.attachmentId == "fresh" }
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["fresh"])
    }

    func testRefreshReplacesSnapshotAndRemovesItemsAbsentFromAuthoritativeProjection() async throws {
        var callCount = 0
        let removed = makeItem(id: "removed", createdAt: Date(timeIntervalSince1970: 3))
        let retained = makeItem(id: "retained", createdAt: Date(timeIntervalSince1970: 2))
        let added = makeItem(id: "added", createdAt: Date(timeIntervalSince1970: 4))
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, cursor in
            XCTAssertNil(cursor)
            callCount += 1
            if callCount == 1 {
                return E2eeChannelAttachmentListPage(
                    items: [removed, retained],
                    nextCursor: nil,
                    hasMore: false,
                    unavailableCount: 0
                )
            }
            return E2eeChannelAttachmentListPage(
                items: [added, retained],
                nextCursor: nil,
                hasMore: false,
                unavailableCount: 0
            )
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.items.count == 2 }
        XCTAssertEqual(
            controller.snapshot.items.map(\.attachmentId),
            ["removed", "retained"]
        )

        controller.refresh()
        try await waitUntil {
            controller.snapshot.phase == .loaded && callCount == 2
        }

        XCTAssertEqual(
            controller.snapshot.items.map(\.attachmentId),
            ["added", "retained"]
        )
        XCTAssertFalse(controller.snapshot.items.contains { $0.attachmentId == "removed" })
    }

    func testWebSocketAndScopeSyncOverlapConvergesAfterPageAndRefreshReconciliation() async throws {
        let nextCursor = E2eeChannelAttachmentListCursor(
            createdAt: "2026-08-17T10:00:00Z",
            attachmentId: "shared"
        )
        let websocketItem = makeItem(
            id: "shared",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let scopeSyncCopy = makeItem(
            id: "shared",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let catchUpItem = makeItem(
            id: "catch-up",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var callCount = 0
        let controller = E2eeChannelAttachmentListController(cid: cid) { _, _, cursor in
            callCount += 1
            switch callCount {
            case 1:
                // The first Channel Info projection is observed after realtime WebSocket delivery.
                XCTAssertNil(cursor)
                return E2eeChannelAttachmentListPage(
                    items: [websocketItem],
                    nextCursor: nextCursor,
                    hasMore: true,
                    unavailableCount: 0
                )
            case 2:
                // The catch-up page overlaps the same attachment materialized by scope sync.
                XCTAssertEqual(cursor, nextCursor)
                return E2eeChannelAttachmentListPage(
                    items: [scopeSyncCopy, catchUpItem],
                    nextCursor: nil,
                    hasMore: false,
                    unavailableCount: 0
                )
            default:
                // The next authoritative refresh may observe both delivery paths before the
                // projection settles. Duplicate IDs must still converge to one list item.
                XCTAssertNil(cursor)
                return E2eeChannelAttachmentListPage(
                    items: [scopeSyncCopy, websocketItem, catchUpItem],
                    nextCursor: nil,
                    hasMore: false,
                    unavailableCount: 0
                )
            }
        }

        controller.startIfNeeded()
        try await waitUntil { controller.snapshot.items.map(\.attachmentId) == ["shared"] }
        controller.loadNextPage()
        try await waitUntil {
            controller.snapshot.phase == .loaded && controller.snapshot.items.count == 2
        }

        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["shared", "catch-up"])
        XCTAssertEqual(
            controller.snapshot.items.filter { $0.attachmentId == "shared" }.count,
            1
        )

        controller.refresh()
        try await waitUntil { controller.snapshot.phase == .loaded && callCount == 3 }

        XCTAssertEqual(controller.snapshot.items.map(\.attachmentId), ["shared", "catch-up"])
        XCTAssertEqual(
            controller.snapshot.items.filter { $0.attachmentId == "shared" }.count,
            1
        )
    }

    private func makeItem(id: String, createdAt: Date) -> E2eeChannelAttachmentListItem {
        E2eeChannelAttachmentListItem(
            attachmentId: id,
            messageId: "message-\(id)",
            cid: cid,
            createdByUserId: "sender",
            createdAt: createdAt,
            updatedAt: createdAt,
            attachment: AnyMessageAttachment(
                id: AttachmentId(cid: cid, messageId: "message-\(id)", index: 0),
                type: .file,
                payload: Data(),
                thumbnailData: nil,
                uploadingState: nil
            ),
            displayName: "\(id).bin",
            mimeType: "application/octet-stream",
            plaintextSize: 1
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !predicate() {
            if DispatchTime.now().uptimeNanoseconds - startedAt > timeoutNanoseconds {
                throw TestError.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private enum TestError: Error {
        case requestFailed
        case timedOut
    }
}
