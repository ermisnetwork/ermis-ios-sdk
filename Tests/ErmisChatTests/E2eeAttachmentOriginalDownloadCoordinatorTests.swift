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

    func testRuntimeNoSpaceIsClassifiedAsInsufficientStorage() {
        let posixError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let cocoaError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteOutOfSpace.rawValue
        )

        assertInsufficientStorage(
            E2eeAttachmentOriginalDownloadCoordinator.classifyDiskError(
                posixError,
                stage: .download
            )
        )
        assertInsufficientStorage(
            E2eeAttachmentOriginalDownloadCoordinator.classifyDiskError(
                cocoaError,
                stage: .export
            )
        )
    }

    func testPlaybackDirectoryResetRemovesPlaintextFromPreviousProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeOriginalDownloadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stalePlaintext = root.appendingPathComponent("stale-video.mov")
        try Data("plaintext".utf8).write(to: stalePlaintext)

        try E2eeAttachmentOriginalDownloadCoordinator.resetPlaybackDirectory(root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePlaintext.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testMainAppCleanupRunsOnlyOncePerPlaybackDirectoryInAProcess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("E2eeLaunchCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("stale.mov")
        try Data("stale".utf8).write(to: stale)

        try E2eeAttachmentPlaintextLaunchCleanupRegistry.shared.performOnce(directory: root) {
            try E2eeAttachmentOriginalDownloadCoordinator.resetPlaybackDirectory(root)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))

        let active = root.appendingPathComponent("active.mov")
        try Data("active".utf8).write(to: active)
        try E2eeAttachmentPlaintextLaunchCleanupRegistry.shared.performOnce(directory: root) {
            try E2eeAttachmentOriginalDownloadCoordinator.resetPlaybackDirectory(root)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: active.path))
    }

    func testRetryableDecryptFailuresRetainVerifiedCiphertext() {
        XCTAssertTrue(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRetainVerifiedCiphertext(
                after: E2eeAttachmentOriginalDownloadError.insufficientStorage
            )
        )
        XCTAssertTrue(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRetainVerifiedCiphertext(
                after: E2eeAttachmentOriginalDownloadError.protectedDataUnavailable
            )
        )
        XCTAssertTrue(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRetainVerifiedCiphertext(
                after: CancellationError()
            )
        )
        XCTAssertFalse(
            E2eeAttachmentOriginalDownloadCoordinator.shouldRetainVerifiedCiphertext(
                after: E2eeAttachmentOriginalDownloadError.plaintextHashMismatch
            )
        )
    }

    func testWaitingForUnlockProgressKeepsVerifiedCiphertextByteCount() {
        let progress = E2eeAttachmentOriginalDownloadProgress(
            phase: .waitingForUnlock,
            completedCiphertextBytes: 42,
            totalCiphertextBytes: 42
        )

        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.phase, .waitingForUnlock)
    }

    func testVerifiedCiphertextRetryDoesNotReserveCiphertextTwice() {
        let mebibyte = UInt64(1024 * 1024)
        XCTAssertEqual(
            E2eeAttachmentOriginalDownloadCoordinator.requiredStorageBytes(
                ciphertextSize: 300 * mebibyte,
                plaintextSize: 299 * mebibyte,
                requiresCiphertextStaging: true
            ),
            699 * mebibyte
        )
        XCTAssertEqual(
            E2eeAttachmentOriginalDownloadCoordinator.requiredStorageBytes(
                ciphertextSize: 300 * mebibyte,
                plaintextSize: 299 * mebibyte,
                requiresCiphertextStaging: false
            ),
            399 * mebibyte
        )
    }

    func testOriginalLeaseReleasesExactlyOnce() {
        let releaseCount = LockedCounter()
        let lease = E2eeAttachmentOriginalLease(
            localURL: URL(fileURLWithPath: "/tmp/original.mov"),
            releaseHandler: { releaseCount.increment() }
        )

        lease.release()
        lease.release()

        XCTAssertEqual(releaseCount.value, 1)
    }

    func testOriginalLeaseDeinitReleasesConsumer() {
        let releaseCount = LockedCounter()
        var lease: E2eeAttachmentOriginalLease? = E2eeAttachmentOriginalLease(
            localURL: URL(fileURLWithPath: "/tmp/original.jpg"),
            releaseHandler: { releaseCount.increment() }
        )

        XCTAssertNotNil(lease)
        lease = nil

        XCTAssertEqual(releaseCount.value, 1)
    }

    private func assertInsufficientStorage(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let downloadError = error as? E2eeAttachmentOriginalDownloadError,
              case .insufficientStorage = downloadError else {
            return XCTFail("Expected insufficientStorage, got \(error)", file: file, line: line)
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
