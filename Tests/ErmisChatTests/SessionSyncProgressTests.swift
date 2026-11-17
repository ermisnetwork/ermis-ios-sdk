import XCTest
@testable import ErmisChat

final class SessionSyncProgressTests: XCTestCase {
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
