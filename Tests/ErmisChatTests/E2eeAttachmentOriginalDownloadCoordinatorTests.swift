//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import XCTest

final class E2eeAttachmentOriginalDownloadCoordinatorTests: XCTestCase {
    func testSchedulerBoundsConcurrentDownloadsAndReleasesNextWaiter() async throws {
        let scheduler = E2eeAttachmentOriginalDownloadScheduler(maximumConcurrentDownloads: 1)
        let first = try await scheduler.acquire()

        let secondTask = Task { try await scheduler.acquire() }
        await Task.yield()
        XCTAssertFalse(secondTask.isCancelled)

        await scheduler.release(first)
        let second = try await secondTask.value
        await scheduler.release(second)
    }

    func testCancelingQueuedDownloadDoesNotConsumeReleasedSlot() async throws {
        let scheduler = E2eeAttachmentOriginalDownloadScheduler(maximumConcurrentDownloads: 1)
        let first = try await scheduler.acquire()
        let canceledWaiter = Task { try await scheduler.acquire() }
        await Task.yield()
        canceledWaiter.cancel()

        do {
            _ = try await canceledWaiter.value
            XCTFail("A cancelled queued original must not acquire an interactive slot")
        } catch is CancellationError {
            // Expected.
        }

        await scheduler.release(first)
        let replacement = try await scheduler.acquire()
        await scheduler.release(replacement)
    }

    func testGrantRenewalPolicyRetriesOnlyFirstUnauthorizedResponse() {
        XCTAssertTrue(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRenewGrant(
                afterHTTPStatus: 401,
                grantAttempt: 0
            )
        )
        XCTAssertTrue(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRenewGrant(
                afterHTTPStatus: 403,
                grantAttempt: 0
            )
        )
        XCTAssertFalse(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRenewGrant(
                afterHTTPStatus: 403,
                grantAttempt: 1
            )
        )
        XCTAssertFalse(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRenewGrant(
                afterHTTPStatus: 500,
                grantAttempt: 0
            )
        )
    }
}
