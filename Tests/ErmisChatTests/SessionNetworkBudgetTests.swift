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
    func testMetadataPassesBacklogWithBoundedFairnessAndNormalFifo() throws {
        let budget = SessionNetworkBudget()
        var active: [SessionNetworkPermit] = [], selected: [String] = []
        var permits: [String: SessionNetworkPermit] = [:]
        for _ in 0..<2 { budget.submit({ active.append($0) }, reject: { XCTFail() }) }
        for name in ["normal-first", "normal-second"] {
            budget.submit({ permits[name] = $0; selected.append(name) }, reject: { XCTFail() })
        }
        budget.submit({ permits["metadata-first"] = $0; selected.append("metadata-first") },
                      priority: .metadata, reject: { XCTFail() })
        XCTAssertTrue(selected.isEmpty, "Priority does not exceed the two active permits")
        active[0].release()
        XCTAssertEqual(selected, ["metadata-first"])
        budget.submit({ permits["metadata-second"] = $0; selected.append("metadata-second") },
                      priority: .metadata, reject: { XCTFail() })
        active[1].release()
        XCTAssertEqual(selected, ["metadata-first", "normal-first"], "A promoted read cannot starve oldest normal work")
        try XCTUnwrap(permits["metadata-first"]).release()
        XCTAssertEqual(selected, ["metadata-first", "normal-first", "metadata-second"])
        try XCTUnwrap(permits["normal-first"]).release()
        XCTAssertEqual(selected, ["metadata-first", "normal-first", "metadata-second", "normal-second"])
        permits.values.forEach { $0.release() }
    }

    func testMetadataQueueRetiresWithSessionWithoutPreemptingActiveWork() throws {
        let budget = SessionNetworkBudget(), owner = budget.captureOwner()
        var active: [SessionNetworkPermit] = [], started = false, rejected = 0
        for _ in 0..<2 { budget.submit({ active.append($0) }, reject: { XCTFail() }) }
        budget.submit({ _ in started = true }, priority: .metadata, reject: { rejected += 1 })
        budget.invalidate()
        XCTAssertEqual(rejected, 1)
        XCTAssertThrowsError(try owner())
        active.forEach { $0.release() }
        XCTAssertFalse(started)
    }

    func testDefaultRequestsRetainFifoAndQueueBound() {
        let budget = SessionNetworkBudget()
        var active: [SessionNetworkPermit] = [], order: [Int] = [], rejected = 0
        for _ in 0..<2 { budget.submit({ active.append($0) }, reject: { XCTFail() }) }
        for n in 0..<256 {
            budget.submit({ permit in order.append(n); permit.release() }, reject: { XCTFail() })
        }
        budget.submit({ _ in XCTFail("Queue bound exceeded") }, priority: .metadata, reject: { rejected += 1 })
        XCTAssertEqual(rejected, 1)
        active[0].release(); active[1].release()
        XCTAssertEqual(order, Array(0..<256))
    }

}
