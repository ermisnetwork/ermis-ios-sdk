import XCTest
@testable import ErmisChat

final class MlsKeyPackageRefillScheduleTests: XCTestCase {
    func testQuickFailureContinuationIsAdmittedWithoutAnotherHealthEvent() {
        var schedule = MlsKeyPackageRefillSchedule()
        XCTAssertTrue(schedule.begin(at: 100))
        schedule.complete(at: 100.1)
        let delay = schedule.wakeDelay(requestedAt: 1030, wallTime: 1000.1, uptime: 100.1)
        XCTAssertTrue(schedule.begin(at: 100.1 + delay), "The only scheduled wake must survive the unchanged cooldown")
    }

    func testDurableRetryDateAndSingleFlightArePreserved() {
        var schedule = MlsKeyPackageRefillSchedule()
        XCTAssertTrue(schedule.begin(at: 100))
        XCTAssertFalse(schedule.begin(at: 1000))
        schedule.complete(at: 1000)
        XCTAssertFalse(schedule.begin(at: 1059.9))
        let delay = schedule.wakeDelay(requestedAt: 2300, wallTime: 2000, uptime: 1010)
        XCTAssertEqual(delay, 300)
        XCTAssertTrue(schedule.begin(at: 1010 + delay))
    }

    func testWallClockJumpCannotConsumeContinuationInsideMonotonicCooldown() {
        var schedule = MlsKeyPackageRefillSchedule()
        XCTAssertTrue(schedule.begin(at: 0))
        schedule.complete(at: 0)
        let delay = schedule.wakeDelay(requestedAt: 1030, wallTime: 5000, uptime: 5)
        XCTAssertGreaterThanOrEqual(delay, 55)
        XCTAssertTrue(schedule.begin(at: 5 + delay))
    }
}
