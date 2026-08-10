//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeDurableTransferStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeDurableTransferStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testAttemptSurvivesStoreRecreationAndMapsOpaqueToken() throws {
        let attempt = makeAttempt(accountId: "account-a")
        try E2eeDurableTransferStore(rootURL: directory).insert(attempt)

        let relaunched = E2eeDurableTransferStore(rootURL: directory)
        let records = try relaunched.hydrate()

        XCTAssertEqual(records, [attempt])
        XCTAssertEqual(try relaunched.attempt(taskToken: attempt.taskToken), attempt)
        XCTAssertNil(try relaunched.attempt(taskToken: UUID().uuidString))
    }

    func testProgressCannotRegressAcrossRetryOrReconciliation() throws {
        let store = E2eeDurableTransferStore(rootURL: directory)
        let attempt = makeAttempt(accountId: "account-a", totalBytes: 100)
        try store.insert(attempt)
        _ = try store.update(attemptId: attempt.attemptId) {
            $0.phase = .encrypting
            $0.completedBytes = 20
        }
        _ = try store.update(attemptId: attempt.attemptId) {
            $0.phase = .uploading
            $0.completedBytes = 60
        }

        XCTAssertThrowsError(
            try store.update(attemptId: attempt.attemptId) {
                $0.phase = .reconciling
                $0.completedBytes = 59
            }
        ) { error in
            XCTAssertEqual(error as? E2eeTransferStateError, .progressRegression)
        }
        XCTAssertEqual(try store.hydrate().first?.completedBytes, 60)
    }

    func testInvalidTransitionDoesNotOverwriteDurableRecord() throws {
        let store = E2eeDurableTransferStore(rootURL: directory)
        let attempt = makeAttempt(accountId: "account-a")
        try store.insert(attempt)

        XCTAssertThrowsError(
            try store.update(attemptId: attempt.attemptId) { $0.phase = .confirmed }
        ) { error in
            XCTAssertEqual(
                error as? E2eeTransferStateError,
                .invalidTransition(from: .preparing, to: .confirmed)
            )
        }
        XCTAssertEqual(try store.hydrate().first?.phase, .preparing)
    }

    func testAccountScopedRemovalDoesNotAffectOtherAccount() throws {
        let store = E2eeDurableTransferStore(rootURL: directory)
        let first = makeAttempt(accountId: "account-a")
        let second = makeAttempt(accountId: "account-b")
        try store.insert(first)
        try store.insert(second)

        XCTAssertEqual(try store.removeAll(accountId: "account-a"), [first])
        XCTAssertEqual(try store.hydrate(), [second])
    }

    func testPublicProgressDoesNotExposeOpaqueToken() throws {
        let attempt = makeAttempt(accountId: "account-a", totalBytes: 200)
        let progress = attempt.publicProgress

        XCTAssertEqual(progress.phase, .preparing)
        XCTAssertEqual(progress.fractionCompleted, 0)
        let encoded = String(data: try JSONEncoder.default.encode(progress.phase), encoding: .utf8)
        XCTAssertFalse(encoded?.contains(attempt.taskToken) == true)
    }

    func testPresentationProgressDoesNotReachOneBeforeConfirmation() {
        for phase in [E2eeTransferPhase.uploading, .waitingForSystem, .finalizing, .sending] {
            let progress = E2eeTransferProgress(
                phase: phase,
                completedBytes: 100,
                totalBytes: 100,
                failureReason: nil
            )
            XCTAssertEqual(progress.fractionCompleted, 1)
            XCTAssertEqual(progress.presentationFractionCompleted, 0.99)
        }
    }

    func testPresentationProgressReachesOneOnlyAfterConfirmation() {
        let progress = E2eeTransferProgress(
            phase: .confirmed,
            completedBytes: 100,
            totalBytes: 100,
            failureReason: nil
        )

        XCTAssertEqual(progress.presentationFractionCompleted, 1)
    }

    func testJournalAppendDrainAndAtomicCompaction() throws {
        let url = directory.appendingPathComponent("journal/events.bin")
        let journal = BackgroundTransferEventJournal(url: url)
        let first = makeEvent(taskToken: UUID().uuidString, taskIdentifier: 1, eTag: "etag-1")
        let second = makeEvent(taskToken: UUID().uuidString, taskIdentifier: 2, eTag: "etag-2")

        try journal.append(first)
        try journal.append(second)
        XCTAssertEqual(try journal.readAll(), [first, second])

        try journal.compact(removingEventIds: [first.eventId])

        XCTAssertEqual(try journal.readAll(), [second])
    }

    func testJournalPayloadCannotContainSensitiveTransferIdentifiers() throws {
        let url = directory.appendingPathComponent("journal/events.bin")
        let journal = BackgroundTransferEventJournal(url: url)
        let event = makeEvent(taskToken: UUID().uuidString, taskIdentifier: 3, eTag: nil)
        try journal.append(event)

        let bytes = try Data(contentsOf: url)
        let raw = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["account-a", "messaging:channel", "message-id", "attachment-id", "https://"] {
            XCTAssertFalse(raw.contains(forbidden))
        }
        XCTAssertTrue(raw.contains(event.taskToken))
    }

    func testJournalRejectsNonOpaqueTaskToken() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let event = makeEvent(taskToken: "account-a:attachment-id", taskIdentifier: 4, eTag: nil)

        XCTAssertThrowsError(try journal.append(event)) { error in
            XCTAssertEqual(
                error as? BackgroundTransferEventJournalError,
                .invalidOpaqueToken
            )
        }
    }

    func testCallbackArrivingBeforeStoreHydrationIsAppliedAfterAttemptPersists() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let token = UUID().uuidString
        let event = makeEvent(taskToken: token, taskIdentifier: 21, eTag: nil)
        try journal.append(event)
        XCTAssertEqual(try journal.readAll(), [event])

        let attempt = makeSinglePutAttempt(taskToken: token, taskIdentifier: 21)
        try store.insert(attempt)
        let drainer = E2eeBackgroundTransferEventDrainer(store: store, journal: journal)

        XCTAssertEqual(try drainer.drain(), 1)
        // A successful completion durably accounts for the full asset, even when the final
        // delegate byte sample is stale or smaller than the expected upload size.
        XCTAssertEqual(try store.hydrate().first?.completedBytes, 100)
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testLateSuccessfulCallbackRecoversBackgroundTaskMissingAttempt() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let token = UUID().uuidString
        var attempt = makeSinglePutAttempt(taskToken: token, taskIdentifier: 27)
        attempt.phase = .failedRetryable
        attempt.failureReason = .backgroundTaskMissing
        try store.insert(attempt)
        try journal.append(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: 27,
                completedBytes: 100,
                totalBytes: 100,
                httpStatus: 200,
                eTag: nil,
                error: .none
            )
        )

        XCTAssertEqual(
            try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain(),
            1
        )

        let recovered = try XCTUnwrap(store.hydrate().first)
        XCTAssertEqual(recovered.phase, .finalizing)
        XCTAssertNil(recovered.failureReason)
        XCTAssertTrue(try XCTUnwrap(recovered.assets.first).isUploaded)
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testSuccessfulOriginalAndPreviewCallbacksAdvanceWaitingAttemptToFinalizing() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let originalToken = UUID().uuidString
        let previewToken = UUID().uuidString
        let attachmentId = UUID().uuidString
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .waitingForSystem,
            totalBytes: 125
        )
        attempt.assets = [
            PendingE2eeAsset(
                attachmentId: attachmentId,
                assetId: UUID().uuidString,
                kind: .original,
                sourceURL: nil,
                canonicalCiphertextURL: nil,
                ciphertextSize: 100,
                ciphertextSha256: String(repeating: "a", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                taskIdentifier: 31,
                taskToken: originalToken,
                parts: []
            ),
            PendingE2eeAsset(
                attachmentId: attachmentId,
                assetId: UUID().uuidString,
                kind: .preview,
                sourceURL: nil,
                canonicalCiphertextURL: nil,
                ciphertextSize: 25,
                ciphertextSha256: String(repeating: "b", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                taskIdentifier: 32,
                taskToken: previewToken,
                parts: []
            )
        ]
        try store.insert(attempt)
        try journal.append(
            BackgroundTransferEvent(
                taskToken: previewToken,
                taskIdentifier: 32,
                completedBytes: 25,
                totalBytes: 25,
                httpStatus: 200,
                eTag: nil,
                error: .none
            )
        )
        try journal.append(
            BackgroundTransferEvent(
                taskToken: originalToken,
                taskIdentifier: 31,
                completedBytes: 100,
                totalBytes: 100,
                httpStatus: 200,
                eTag: nil,
                error: .none
            )
        )

        XCTAssertEqual(
            try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain(),
            2
        )

        let completed = try store.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(completed.phase, .finalizing)
        XCTAssertEqual(completed.completedBytes, 125)
        XCTAssertTrue(completed.assets.allSatisfy(\.isUploaded))
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testStaleCallbackIsDrainedWithoutMutatingReplacementAttempt() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let current = makeSinglePutAttempt(taskToken: UUID().uuidString, taskIdentifier: 22)
        try store.insert(current)
        let stale = makeEvent(taskToken: UUID().uuidString, taskIdentifier: 22, eTag: nil)
        try journal.append(stale)

        XCTAssertEqual(
            try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain(),
            1
        )
        XCTAssertEqual(try store.hydrate(), [current])
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testMultipartETagIsDurableBeforeJournalCompaction() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let token = UUID().uuidString
        let attempt = makeMultipartAttempt(taskToken: token, taskIdentifier: 23)
        try store.insert(attempt)
        let event = makeEvent(taskToken: token, taskIdentifier: 23, eTag: "part-etag")
        try journal.append(event)

        _ = try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain()

        let relaunched = try E2eeDurableTransferStore(rootURL: directory).hydrate().first
        XCTAssertEqual(relaunched?.assets.first?.parts.first?.eTag, "part-etag")
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testProgressCallbackDoesNotMarkSinglePutUploaded() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let token = UUID().uuidString
        try store.insert(makeSinglePutAttempt(taskToken: token, taskIdentifier: 24))
        try journal.append(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: 24,
                kind: .progress,
                completedBytes: 50,
                totalBytes: 100,
                httpStatus: nil,
                eTag: nil,
                error: .none
            )
        )

        _ = try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain()

        let asset = try XCTUnwrap(store.hydrate().first?.assets.first)
        XCTAssertFalse(asset.isUploaded)
        XCTAssertEqual(asset.taskToken, token)
        XCTAssertEqual(asset.taskIdentifier, 24)
    }

    func testCompletionWithoutHTTPResponseFailsClosed() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let token = UUID().uuidString
        try store.insert(makeSinglePutAttempt(taskToken: token, taskIdentifier: 25))
        try journal.append(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: 25,
                completedBytes: 100,
                totalBytes: 100,
                httpStatus: nil,
                eTag: nil,
                error: .none
            )
        )

        _ = try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain()

        let attempt = try XCTUnwrap(store.hydrate().first)
        XCTAssertEqual(attempt.phase, .failedTerminal)
        XCTAssertEqual(attempt.failureReason, .invalidServerResponse)
    }

    func testTransientHTTPStatusIsRetryable() throws {
        let journal = BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("journal/events.bin")
        )
        let store = E2eeDurableTransferStore(rootURL: directory)
        let token = UUID().uuidString
        try store.insert(makeSinglePutAttempt(taskToken: token, taskIdentifier: 26))
        try journal.append(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: 26,
                completedBytes: 100,
                totalBytes: 100,
                httpStatus: 503,
                eTag: nil,
                error: .none
            )
        )

        _ = try E2eeBackgroundTransferEventDrainer(store: store, journal: journal).drain()

        let attempt = try XCTUnwrap(store.hydrate().first)
        XCTAssertEqual(attempt.phase, .failedRetryable)
        XCTAssertEqual(attempt.failureReason, .networkUnavailable)
    }

    private func makeAttempt(
        accountId: String,
        totalBytes: Int64 = 0
    ) -> PendingE2eeTransferAttempt {
        PendingE2eeTransferAttempt(
            accountId: accountId,
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            totalBytes: totalBytes,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeEvent(
        taskToken: String,
        taskIdentifier: Int,
        eTag: String?
    ) -> BackgroundTransferEvent {
        BackgroundTransferEvent(
            taskToken: taskToken,
            taskIdentifier: taskIdentifier,
            completedBytes: 10,
            totalBytes: 100,
            httpStatus: 200,
            eTag: eTag,
            error: .none
        )
    }

    private func makeSinglePutAttempt(
        taskToken: String,
        taskIdentifier: Int
    ) -> PendingE2eeTransferAttempt {
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .uploading,
            totalBytes: 100,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        attempt.assets = [
            PendingE2eeAsset(
                attachmentId: UUID().uuidString,
                assetId: UUID().uuidString,
                kind: .original,
                sourceURL: nil,
                canonicalCiphertextURL: nil,
                ciphertextSize: 100,
                ciphertextSha256: String(repeating: "a", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: nil,
                taskIdentifier: taskIdentifier,
                taskToken: taskToken,
                parts: []
            )
        ]
        return attempt
    }

    private func makeMultipartAttempt(
        taskToken: String,
        taskIdentifier: Int
    ) -> PendingE2eeTransferAttempt {
        var attempt = makeSinglePutAttempt(taskToken: UUID().uuidString, taskIdentifier: 99)
        attempt.assets[0].uploadMode = .multipart
        attempt.assets[0].multipartPartSize = 100
        attempt.assets[0].taskIdentifier = nil
        attempt.assets[0].taskToken = nil
        attempt.assets[0].parts = [
            PendingE2eeMultipartPart(
                number: 1,
                offset: 0,
                size: 100,
                putURL: URL(string: "https://upload.example.test/part-1"),
                eTag: nil,
                taskIdentifier: taskIdentifier,
                taskToken: taskToken,
                localFileURL: nil
            )
        ]
        return attempt
    }
}
