import XCTest
@testable import ErmisChat

final class SessionNetworkBudgetTests: XCTestCase {
    func testTwoTasksAndRetiredQueuedOwnerCannotStartInNextSession() throws {
        let budget = SessionNetworkBudget(), owner = budget.captureOwner()
        var permits: [SessionNetworkPermit] = [], queued = false, rejected = false, cancelled = 0
        budget.submit({ permit in permits.append(permit); permit.attachCancellation { cancelled += 1 } }, reject: { XCTFail() })
        budget.submit({ permit in permits.append(permit); permit.attachCancellation { cancelled += 1 } }, reject: { XCTFail() })
        budget.submit({ _ in queued = true }, reject: { rejected = true })
        XCTAssertEqual(permits.count, 2); XCTAssertFalse(queued)
        try owner(); budget.invalidate(); XCTAssertThrowsError(try owner())
        XCTAssertTrue(rejected); XCTAssertEqual(cancelled, 2)
        var next = false
        budget.submit({ permit in next = true; permit.release() }, reject: { XCTFail() })
        XCTAssertFalse(next, "Old running HTTP must confirm completion before reusing its slot")
        permits[0].release(); XCTAssertTrue(next)
        permits[0].release(); permits[1].release()
        XCTAssertFalse(queued)
    }
}
