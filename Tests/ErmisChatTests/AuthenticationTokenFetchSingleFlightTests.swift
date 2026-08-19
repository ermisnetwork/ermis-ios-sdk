//
// Copyright 2026 Ermis Inc.
//

import XCTest
@testable import ErmisChat

final class AuthenticationTokenFetchSingleFlightTests: XCTestCase {
    func testConcurrentRequestersCreateExactlyOneTokenFetchCycle() {
        let flight = AuthenticationTokenFetchSingleFlight()
        let queue = DispatchQueue(label: "network.ermis.auth-single-flight-tests", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var starters = 0
        var callbackCount = 0

        for _ in 0..<100 {
            group.enter()
            queue.async {
                let outcome = flight.join { _ in
                    lock.lock()
                    callbackCount += 1
                    lock.unlock()
                }
                if outcome.shouldStart {
                    lock.lock()
                    starters += 1
                    lock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(starters, 1)
        XCTAssertTrue(flight.isActive)

        let finished = flight.finish()
        XCTAssertTrue(finished.wasActive)
        finished.completions.forEach { $0(nil) }
        XCTAssertTrue(flight.completeDelivery())
        XCTAssertEqual(callbackCount, 100)
        XCTAssertFalse(flight.isActive)
    }

    func testFinishIsIdempotentAndCannotDrainNextCycle() {
        let flight = AuthenticationTokenFetchSingleFlight()
        var firstCycleCallbacks = 0
        var secondCycleCallbacks = 0

        XCTAssertTrue(flight.join { _ in firstCycleCallbacks += 1 }.shouldStart)
        let first = flight.finish()
        first.completions.forEach { $0(nil) }
        XCTAssertTrue(flight.completeDelivery())
        XCTAssertEqual(firstCycleCallbacks, 1)

        let duplicateFinish = flight.finish()
        XCTAssertFalse(duplicateFinish.wasActive)
        XCTAssertTrue(duplicateFinish.completions.isEmpty)

        XCTAssertTrue(flight.join { _ in secondCycleCallbacks += 1 }.shouldStart)
        XCTAssertEqual(secondCycleCallbacks, 0)
        let second = flight.finish()
        second.completions.forEach { $0(nil) }
        XCTAssertTrue(flight.completeDelivery())
        XCTAssertEqual(secondCycleCallbacks, 1)
    }

    func testRequesterJoiningActiveCycleDoesNotBecomeStarter() {
        let flight = AuthenticationTokenFetchSingleFlight()

        XCTAssertTrue(flight.join { _ in }.shouldStart)
        XCTAssertFalse(flight.join { _ in }.shouldStart)
        XCTAssertFalse(flight.join { _ in }.shouldStart)
        XCTAssertEqual(flight.finish().completions.count, 3)
    }

    func testExternalModeTransitionsRunExactlyOncePerCycle() {
        let flight = AuthenticationTokenFetchSingleFlight()
        var startCount = 0
        var finishCount = 0

        XCTAssertTrue(flight.join(
            { _ in },
            onStart: { startCount += 1 }
        ).shouldStart)
        XCTAssertFalse(flight.join(
            { _ in },
            onStart: { startCount += 1 }
        ).shouldStart)
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(flight.finish().wasActive)
        XCTAssertFalse(flight.finish().wasActive)
        XCTAssertTrue(flight.completeDelivery(onBecomeIdle: { finishCount += 1 }))
        XCTAssertEqual(finishCount, 1)

        XCTAssertTrue(flight.join(
            { _ in },
            onStart: { startCount += 1 }
        ).shouldStart)
        XCTAssertEqual(startCount, 2)
        XCTAssertTrue(flight.finish().wasActive)
        XCTAssertTrue(flight.completeDelivery(onBecomeIdle: { finishCount += 1 }))
        XCTAssertEqual(finishCount, 2)
    }

    func testLateCompletionCannotFinishNewCycle() {
        let flight = AuthenticationTokenFetchSingleFlight()

        let firstCycle = flight.join { _ in }.cycleId
        XCTAssertTrue(flight.finish(cycleId: firstCycle).wasActive)
        XCTAssertTrue(flight.completeDelivery())

        let secondCycle = flight.join { _ in }.cycleId
        XCTAssertNotEqual(firstCycle, secondCycle)
        XCTAssertFalse(flight.finish(cycleId: firstCycle).wasActive)
        XCTAssertTrue(flight.isActive(cycleId: secondCycle))
        XCTAssertTrue(flight.finish(cycleId: secondCycle).wasActive)
        XCTAssertTrue(flight.completeDelivery())
    }

    func testOlderDeliveryCannotExitModeWhileNewCycleOrDeliveryExists() {
        let flight = AuthenticationTokenFetchSingleFlight()
        var exitCount = 0

        let firstCycle = flight.join { _ in }.cycleId
        XCTAssertTrue(flight.finish(cycleId: firstCycle).wasActive)

        let secondCycle = flight.join { _ in }.cycleId
        XCTAssertFalse(flight.completeDelivery(onBecomeIdle: { exitCount += 1 }))
        XCTAssertEqual(exitCount, 0)

        XCTAssertTrue(flight.finish(cycleId: secondCycle).wasActive)
        XCTAssertTrue(flight.completeDelivery(onBecomeIdle: { exitCount += 1 }))
        XCTAssertEqual(exitCount, 1)
    }

    func testExternalModeTransitionsCanReenterWithoutDeadlock() {
        let flight = AuthenticationTokenFetchSingleFlight()
        var sawActiveCycleFromStart = false

        let first = flight.join(
            { _ in },
            onStart: { sawActiveCycleFromStart = flight.isActive }
        )
        XCTAssertTrue(first.shouldStart)
        XCTAssertTrue(sawActiveCycleFromStart)
        XCTAssertTrue(flight.finish(cycleId: first.cycleId).wasActive)

        var replacement: AuthenticationTokenFetchSingleFlight.JoinOutcome?
        XCTAssertTrue(flight.completeDelivery {
            replacement = flight.join { _ in }
        })
        XCTAssertTrue(replacement?.shouldStart == true)

        guard let replacement else {
            XCTFail("Expected the idle callback to create a replacement cycle")
            return
        }
        XCTAssertTrue(flight.finish(cycleId: replacement.cycleId).wasActive)
        XCTAssertTrue(flight.completeDelivery())
    }
}
