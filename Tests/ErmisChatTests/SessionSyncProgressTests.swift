import XCTest
@testable import ErmisChat

final class SessionSyncProgressTests: XCTestCase {
    func testPreparationStageStartsCountersOnlyAtSessionCatchupAndPreservesCycle() throws {
        let p = SessionSyncProgress(), owner = p.owner
        let inventory = ["plain": "standard|plain", "secure": "secure"]
        p.record(scope: "standard|plain", result: .ready, owner: owner)
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: inventory, retry: {})
        let cycle = p.snapshot?.cycleId
        XCTAssertEqual(p.snapshot?.phase, "preparing")
        let point = p.begin("syncing"); p.end(point)
        XCTAssertEqual(p.snapshot?.phase, "preparing")
        p.startReadiness(owner: owner)
        XCTAssertEqual(p.snapshot?.phase, "readiness"); XCTAssertEqual(p.snapshot?.cycleId, cycle)
        p.startReadiness(owner: owner)
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: inventory, retry: {})
        XCTAssertEqual(p.snapshot?.phase, "readiness"); XCTAssertEqual(p.snapshot?.readyChannels, 1)
        p.record(scope: "secure", result: .blocked, owner: owner)
        XCTAssertEqual(p.snapshot?.status, "partial")
        p.invalidate()
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["new": "new"], retry: {})
        p.startReadiness(owner: owner)
        XCTAssertEqual(p.snapshot?.phase, "preparing", "The retired session cannot expose the new counter")
    }
    func testInventoryResponseCannotResurrectChannelDeletedDuringItsRequest() throws {
        let p = SessionSyncProgress(), owner = p.owner
        let inventory = ["ready": "ready", "deleted": "deleted"]
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: inventory, retry: {})
        p.record(scope: "ready", result: .ready, owner: owner)
        p.record(scope: "deleted", result: .blocked, owner: owner)
        let held = try XCTUnwrap(p.beginInventory())
        p.excludeChannel("deleted", owner: owner)
        p.finishInventory(held, channels: inventory, retry: {})
        XCTAssertEqual(p.snapshot?.totalChannels, 1)
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        XCTAssertEqual(p.snapshot?.status, "done")
    }
    func testRestoredBootstrapIsQuietAndNewUnfinishedScopeIsVisibleWithoutResettingHistoryProgress() throws {
        let p = SessionSyncProgress(), owner = p.owner
        p.deferRestoredBootstrapPresentation()
        let first = try XCTUnwrap(p.beginInventory())
        XCTAssertNil(p.snapshot)
        p.restoreBootstrapMilestones(["parent"], owner: owner)
        p.finishInventory(first, channels: ["parent": "parent", "topic": "parent"], retry: {})
        XCTAssertNil(p.snapshot, "A completed bootstrap must not reappear on restart")
        let refreshed = try XCTUnwrap(p.beginInventory())
        p.finishInventory(refreshed, channels: ["parent": "parent", "topic": "parent", "new": "new"], retry: {})
        XCTAssertEqual(p.snapshot?.readyChannels, 2)
        XCTAssertEqual(p.snapshot?.totalChannels, 3)
        XCTAssertEqual(p.snapshot?.status, "running")
        p.record(scope: "new", result: .blocked, owner: owner)
        XCTAssertEqual(p.snapshot?.status, "partial")
        XCTAssertEqual(p.snapshot?.readyChannels, 2)
        let history = p.begin("restoring_page")
        XCTAssertEqual(p.snapshot?.phase, "restoring_page")
        p.end(history)
        p.invalidate()
        p.restoreBootstrapMilestones(["new"], owner: owner)
        let replaced = try XCTUnwrap(p.beginInventory())
        p.finishInventory(replaced, channels: ["new": "new"], retry: {})
        XCTAssertEqual(p.snapshot?.readyChannels, 0)
    }

    func testInventoryDenominatorWaitsForCompleteSnapshotAndJobsCannotMakeChannelsReady() throws {
        let p = SessionSyncProgress(), owner = p.owner
        let inventory = try XCTUnwrap(p.beginInventory())
        XCTAssertNil(p.beginInventory(), "Overlapping lifecycle discovery shares the reservation")
        XCTAssertTrue(try XCTUnwrap(p.snapshot).isChannelReadiness)
        XCTAssertNil(p.snapshot?.totalChannels)
        let job = p.begin("syncing")
        p.end(job, partial: true)
        XCTAssertNil(p.snapshot?.totalChannels)
        p.finishInventory(inventory, channels: ["a": "scope-a", "b": "scope-b"], retry: {})
        XCTAssertEqual(p.snapshot?.readyChannels, 0)
        XCTAssertEqual(p.snapshot?.totalChannels, 2)
        XCTAssertEqual(p.snapshot?.status, "running")
        p.record(scope: "scope-a", result: .ready, owner: owner)
        p.record(scope: "scope-b", result: .failed, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        XCTAssertEqual(p.snapshot?.failedChannels, 1)
        XCTAssertEqual(p.snapshot?.status, "partial")
    }

    func testParentAndTopicsUseScopeWeightsAndDuplicateCallbacksAreIdempotent() throws {
        let p = SessionSyncProgress(), owner = p.owner
        let ticket = try XCTUnwrap(p.beginInventory())
        p.finishInventory(ticket, channels: ["parent": "p", "general": "p", "child": "p", "gated": "g"], retry: {})
        for _ in 0..<20 { p.record(scope: "p", result: .ready, owner: owner) }
        XCTAssertEqual(p.snapshot?.readyChannels, 3)
        XCTAssertEqual(p.snapshot?.settledScopes, 1)
        XCTAssertEqual(p.snapshot?.totalScopes, 2)
        p.record(scope: "p", result: .pending, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 3, "A stale syncing callback cannot move progress backwards")
        p.record(scope: "g", result: .ready, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 4)
        XCTAssertEqual(p.snapshot?.status, "done")
    }

    func testEightOfTenSettlesPartialAndExplicitRetryKeepsReadyChannels() throws {
        let p = SessionSyncProgress(), owner = p.owner
        let ticket = try XCTUnwrap(p.beginInventory())
        var retries = 0
        p.finishInventory(ticket, channels: Dictionary(uniqueKeysWithValues: (0..<10).map { ("c\($0)", "s\($0)") }), retry: { retries += 1 })
        let cycle = p.snapshot?.cycleId
        for i in 0..<8 { p.record(scope: "s\(i)", result: .ready, owner: owner) }
        p.record(scope: "s8", result: .blocked, owner: owner)
        p.record(scope: "s9", result: .failed, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 8)
        XCTAssertEqual(p.snapshot?.status, "partial")
        XCTAssertEqual(p.incompleteScopes, ["s8", "s9"])
        p.retry(); p.retry(); XCTAssertEqual(retries, 1, "A tap cannot launch overlapping retries")
        p.record(scope: "s9", result: .pending, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 8)
        XCTAssertEqual(p.snapshot?.cycleId, cycle)
        XCTAssertEqual(p.snapshot?.status, "running")
        p.record(scope: "s9", result: .ready, owner: owner)
        XCTAssertEqual(p.snapshot?.status, "partial")
        p.record(scope: "s8", result: .ready, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 10)
        XCTAssertEqual(p.snapshot?.status, "done")
    }

    func testEmptyInventoryCompletesAndARefreshDoesNotResetSameDataset() throws {
        let p = SessionSyncProgress()
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: [:], retry: {})
        let cycle = p.snapshot?.cycleId
        XCTAssertEqual(p.snapshot?.status, "done")
        XCTAssertEqual(p.snapshot?.totalChannels, 0)
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: [:], retry: {})
        XCTAssertEqual(p.snapshot?.cycleId, cycle)
        XCTAssertEqual(p.snapshot?.readyChannels, 0)
    }

    func testForegroundInventoryRefreshPreservesPartialSnapshotWhileKeepingDiscoveryOwnership() throws {
        let p = SessionSyncProgress(), channels = ["a": "a", "b": "b"]
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: channels, retry: {})
        p.record(scope: "a", result: .ready, owner: p.owner)
        p.record(scope: "b", result: .blocked, owner: p.owner)
        let cycle = p.snapshot?.cycleId
        let refresh = try XCTUnwrap(p.beginInventory())
        XCTAssertTrue(p.isInventoryBootstrapDeferred)
        XCTAssertNil(p.beginInventory(), "Lifecycle refresh still shares one inventory owner")
        XCTAssertEqual(p.snapshot?.phase, "readiness")
        XCTAssertEqual(p.snapshot?.status, "partial")
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        XCTAssertEqual(p.snapshot?.totalChannels, 2)
        p.finishInventory(refresh, channels: channels, retry: {})
        XCTAssertFalse(p.isInventoryBootstrapDeferred)
        XCTAssertEqual(p.snapshot?.cycleId, cycle)
    }

    func testForegroundInventoryRefreshDoesNotRestartCompletedPresentation() throws {
        let p = SessionSyncProgress(), channels = ["a": "a"]
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: channels, retry: {})
        p.record(scope: "a", result: .ready, owner: p.owner)
        let cycle = p.snapshot?.cycleId
        let refresh = try XCTUnwrap(p.beginInventory())
        XCTAssertEqual(p.snapshot?.phase, "readiness")
        XCTAssertEqual(p.snapshot?.status, "done")
        XCTAssertEqual(p.snapshot?.cycleId, cycle)
        p.finishInventory(refresh, channels: channels, retry: {})
        XCTAssertEqual(p.snapshot?.status, "done")
        XCTAssertEqual(p.snapshot?.cycleId, cycle)
    }

    func testMembershipRevisionChangesCycleAndNeverCountsRemovedChannelAsReady() throws {
        let p = SessionSyncProgress(), owner = p.owner
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a": "a", "b": "b"], retry: {})
        p.record(scope: "a", result: .ready, owner: owner)
        let cycle = p.snapshot?.cycleId
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a": "a"], retry: {})
        XCTAssertNotEqual(p.snapshot?.cycleId, cycle)
        XCTAssertEqual(p.snapshot?.totalChannels, 1)
        p.record(scope: "b", result: .ready, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        XCTAssertEqual(p.snapshot?.totalChannels, 1)
    }

    func testRemovalUsesNewSnapshotAndOldScopeCallbacksCannotInflateRemainingChannels() throws {
        let p = SessionSyncProgress(), owner = p.owner
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["parent": "p", "topic": "p", "other": "o"], retry: {})
        p.record(scope: "p", result: .ready, owner: owner)
        let old = p.snapshot?.cycleId
        p.excludeChannel("topic", owner: owner)
        XCTAssertNotEqual(p.snapshot?.cycleId, old)
        XCTAssertEqual(p.snapshot?.readyChannels, 1); XCTAssertEqual(p.snapshot?.totalChannels, 2)
        p.excludeScope("p", owner: owner)
        p.record(scope: "p", result: .ready, owner: owner)
        XCTAssertEqual(p.snapshot?.readyChannels, 0); XCTAssertEqual(p.snapshot?.totalChannels, 1)
        p.record(scope: "o", result: .failed, owner: owner)
        XCTAssertEqual(p.snapshot?.status, "partial")
        p.excludeChannel("other", owner: owner)
        XCTAssertEqual(p.snapshot?.totalChannels, 0); XCTAssertEqual(p.snapshot?.readyChannels, 0)
        XCTAssertEqual(p.snapshot?.status, "done")
    }
    func testActualNewJoinRetiresPreviousReadyCycleWhileOldSyncCallbacksCannotResetIt() throws {
        let p = SessionSyncProgress(), owner = p.owner
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a": "a"], retry: {})
        p.record(scope: "a", result: .ready, owner: owner)
        let cycle = p.snapshot?.cycleId
        p.record(scope: "a", result: .pending, owner: owner)
        XCTAssertEqual(p.snapshot?.cycleId, cycle); XCTAssertEqual(p.snapshot?.readyChannels, 1)
        p.record(scope: "a", result: .pending, owner: owner, invalidateReady: true)
        XCTAssertNotEqual(p.snapshot?.cycleId, cycle)
        XCTAssertEqual(p.snapshot?.readyChannels, 0); XCTAssertEqual(p.snapshot?.status, "running")
        p.record(scope: "a", result: .ready, owner: owner)
        XCTAssertEqual(p.snapshot?.status, "done")
    }

    func testRetiredInventoryAndScopeCallbacksCannotTouchReplacementSession() throws {
        let p = SessionSyncProgress(), oldOwner = p.owner
        let old = try XCTUnwrap(p.beginInventory())
        p.invalidate()
        let new = try XCTUnwrap(p.beginInventory())
        p.finishInventory(old, channels: ["old": "s"], retry: { XCTFail("Old inventory retried") })
        p.failInventory(old, retry: { XCTFail("Old inventory retried") })
        p.record(scope: "s", result: .ready, owner: oldOwner)
        p.finishInventory(new, channels: ["new": "s"], retry: {})
        XCTAssertEqual(p.snapshot?.readyChannels, 0)
        XCTAssertEqual(p.snapshot?.totalChannels, 1)
        XCTAssertEqual(p.snapshot?.status, "running")
    }

    func testFailedInventoryDoesNotInventDenominatorAndHistoryWorkKeepsItsUnits() throws {
        let p = SessionSyncProgress()
        p.failInventory(try XCTUnwrap(p.beginInventory()), retry: {})
        XCTAssertNil(p.snapshot?.totalChannels)
        XCTAssertEqual(p.snapshot?.status, "partial")
        let page = p.begin("restoring_page")
        XCTAssertFalse(try XCTUnwrap(p.snapshot).isChannelReadiness)
        p.end(page, partial: true)
        XCTAssertTrue(try XCTUnwrap(p.snapshot).isChannelReadiness)
        XCTAssertNil(p.snapshot?.totalChannels)
        XCTAssertEqual(p.snapshot?.completed, 1)
        XCTAssertEqual(p.snapshot?.status, "partial")
    }

    func testFinishedHistoryPageDoesNotPermanentlyHideRemainingBootstrapProgress() throws {
        let p = SessionSyncProgress()
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a": "a", "b": "b"], retry: {})
        let page = p.begin("restoring_page")
        p.record(scope: "a", result: .ready, owner: p.owner)
        XCTAssertFalse(try XCTUnwrap(p.snapshot).isChannelReadiness)
        p.end(page, partial: true)
        XCTAssertTrue(try XCTUnwrap(p.snapshot).isChannelReadiness)
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        p.record(scope: "b", result: .blocked, owner: p.owner)
        XCTAssertTrue(try XCTUnwrap(p.snapshot).isChannelReadiness)
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        XCTAssertEqual(p.snapshot?.status, "partial")
    }

    func testTerminalHistoryReturnsToSettledPartialInventoryWithoutFurtherCallbacks() throws {
        let p = SessionSyncProgress(), owner = p.owner
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a":"a", "b":"b"], retry: {})
        p.record(scope: "a", result: .ready, owner: owner)
        p.record(scope: "b", result: .blocked, owner: owner)
        let page = p.begin("restoring_page")
        XCTAssertFalse(try XCTUnwrap(p.snapshot).isChannelReadiness)
        p.end(page, partial: true)
        XCTAssertTrue(try XCTUnwrap(p.snapshot).isChannelReadiness)
        XCTAssertEqual(p.snapshot?.readyChannels, 1)
        XCTAssertEqual(p.snapshot?.totalChannels, 2)
        XCTAssertEqual(p.snapshot?.status, "partial")
    }

    func testPageWithGapsSettlesBeforeNextScrollAndDoesNotPoisonNextPage() {
        let progress = SessionSyncProgress(), first = progress.begin("restoring_page")
        progress.end(first, partial: true)
        XCTAssertEqual(progress.snapshot?.status, "partial")
        XCTAssertEqual(progress.snapshot?.completed, 1)
        let next = progress.begin("restoring_page")
        XCTAssertNotEqual(first.cycle, next.cycle)
        XCTAssertEqual(progress.snapshot?.status, "running")
        progress.end(first, partial: true)
        XCTAssertEqual(progress.snapshot?.completed, 0)
        progress.end(next)
        XCTAssertEqual(progress.snapshot?.status, "done")
        XCTAssertEqual(progress.snapshot?.scheduled, 1)
    }
    func testOverlappingSyncAndPageShareCycleAndRetryWaitsForCompletion() {
        let progress = SessionSyncProgress(), sync = progress.begin("preparing"), page = progress.begin("restoring_page")
        var retries = 0
        XCTAssertEqual(sync.cycle, page.cycle); XCTAssertEqual(progress.snapshot?.scheduled, 2)
        progress.end(page, partial: true, retry: { retries += 1 }); progress.retry(); XCTAssertEqual(retries, 0)
        XCTAssertEqual(progress.snapshot?.status, "running")
        progress.end(sync); XCTAssertEqual(progress.snapshot?.status, "partial"); XCTAssertEqual(progress.snapshot?.completed, 2)
        progress.retry(); XCTAssertEqual(retries, 1)
        progress.end(page); XCTAssertEqual(progress.snapshot?.completed, 2)
    }
    func testRetiredCallbackCannotFinishOrRetryNextAccount() {
        let progress = SessionSyncProgress(), old = progress.begin("preparing")
        progress.invalidate(); let current = progress.begin("syncing")
        progress.end(old, partial: true, retry: { XCTFail("Retired account retried") }); progress.retry()
        XCTAssertEqual(progress.snapshot?.cycleId, current.cycle); XCTAssertEqual(progress.snapshot?.completed, 0)
        progress.end(current); XCTAssertEqual(progress.snapshot?.status, "done")
    }
}
