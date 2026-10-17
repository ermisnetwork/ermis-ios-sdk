import XCTest
@testable import ErmisChat

final class MlsRemovalFreshnessTests: XCTestCase {
    func testDelayedSelfLeaveAfterReaddCannotDeleteCurrentGroup() {
        let removedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(E2eRepository.hasNewerActiveMembership(
            memberCreatedAt: Date(timeIntervalSince1970: 1_001),
            isJoined: true,
            removedAt: removedAt
        ))
    }

    func testOldOrInactiveMembershipDoesNotSuppressRemoval() {
        let removedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(E2eRepository.hasNewerActiveMembership(
            memberCreatedAt: removedAt,
            isJoined: true,
            removedAt: removedAt
        ))
        XCTAssertFalse(E2eRepository.hasNewerActiveMembership(
            memberCreatedAt: Date(timeIntervalSince1970: 1_001),
            isJoined: false,
            removedAt: removedAt
        ))
    }
}
