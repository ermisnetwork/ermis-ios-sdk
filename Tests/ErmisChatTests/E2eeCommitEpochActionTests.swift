import XCTest
@testable import ErmisChat

final class E2eeCommitEpochActionTests: XCTestCase {
    func testLowerTargetIsHistorical() {
        XCTAssertEqual(
            E2eeCommitEpochAction.resolve(localEpoch: 4, targetEpoch: 2),
            .supersedeHistorical
        )
    }

    func testActiveTargetRequiresReplayProofPath() {
        XCTAssertEqual(
            E2eeCommitEpochAction.resolve(localEpoch: 4, targetEpoch: 4),
            .finalizeActive
        )
    }

    func testAdjacentTargetProcessesNextCommit() {
        XCTAssertEqual(
            E2eeCommitEpochAction.resolve(localEpoch: 4, targetEpoch: 5),
            .processNext
        )
    }

    func testFutureGapRemainsBlocked() {
        XCTAssertEqual(
            E2eeCommitEpochAction.resolve(localEpoch: 4, targetEpoch: 6),
            .blockGap
        )
    }

    func testEpochOverflowCannotBeClassifiedAsAdjacent() {
        XCTAssertEqual(
            E2eeCommitEpochAction.resolve(localEpoch: .max, targetEpoch: .max),
            .finalizeActive
        )
    }
}
