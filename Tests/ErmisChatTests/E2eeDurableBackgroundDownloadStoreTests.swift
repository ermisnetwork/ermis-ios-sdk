//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation
@testable import ErmisChat
import XCTest

final class E2eeDurableBackgroundDownloadStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "E2eeDurableBackgroundDownloadStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testLegacyJournalEventWithoutOperationDecodesAsUpload() throws {
        let token = UUID().uuidString
        let json = """
        {
          "eventId":"\(UUID().uuidString)",
          "taskToken":"\(token)",
          "taskIdentifier":7,
          "kind":"completion",
          "completedBytes":24,
          "totalBytes":24,
          "httpStatus":200,
          "error":"none"
        }
        """

        let event = try JSONDecoder.default.decode(
            BackgroundTransferEvent.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(event.operation)
        XCTAssertEqual(event.resolvedOperation, .upload)
    }

    func testUploadDrainerLeavesDownloadEventForDownloadOwner() throws {
        let journal = makeJournal()
        let event = makeEvent(taskToken: UUID().uuidString, taskIdentifier: 8)
        try journal.append(event)

        let uploadStore = E2eeDurableTransferStore(rootURL: directory)
        let drained = try E2eeBackgroundTransferEventDrainer(
            store: uploadStore,
            journal: journal
        ).drain()

        XCTAssertEqual(drained, 0)
        XCTAssertEqual(try journal.readAll(), [event])
    }

    func testDownloadCallbackBeforeProtectedRecordHydrationDrainsAfterRecordPersists() throws {
        let payload = Data("canonical ciphertext".utf8)
        let taskToken = UUID().uuidString
        let taskIdentifier = 42
        let store = E2eeDurableBackgroundDownloadStore(rootURL: directory)
        let fileStore = E2eeBackgroundDownloadFileStore(rootURL: directory)
        let journal = makeJournal()
        let temporaryURL = directory.appendingPathComponent("url-session-temporary")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: temporaryURL)
        _ = try fileStore.captureTemporaryFile(
            at: temporaryURL,
            taskToken: taskToken,
            taskIdentifier: taskIdentifier
        )
        let event = makeEvent(
            taskToken: taskToken,
            taskIdentifier: taskIdentifier,
            completedBytes: Int64(payload.count)
        )
        try journal.append(event)
        XCTAssertEqual(try journal.readAll(), [event])

        let record = makeRecord(
            payload: payload,
            taskToken: taskToken,
            taskIdentifier: taskIdentifier
        )
        try store.insert(record)
        let drained = try E2eeBackgroundDownloadEventDrainer(
            store: store,
            fileStore: fileStore,
            journal: journal
        ).drain()

        XCTAssertEqual(drained, 1)
        let durable = try XCTUnwrap(store.record(taskToken: taskToken))
        XCTAssertEqual(durable.phase, .waitingForUnlock)
        XCTAssertEqual(durable.completedCiphertextBytes, Int64(payload.count))
        let verifiedURL = try XCTUnwrap(durable.verifiedCiphertextURL)
        XCTAssertEqual(try Data(contentsOf: verifiedURL), payload)
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testSuccessfulCompletionProofRemainsWhenCallbackFileHasNotArrived() throws {
        let payload = Data("canonical ciphertext".utf8)
        let taskToken = UUID().uuidString
        let taskIdentifier = 43
        let store = E2eeDurableBackgroundDownloadStore(rootURL: directory)
        let journal = makeJournal()
        try store.insert(
            makeRecord(
                payload: payload,
                taskToken: taskToken,
                taskIdentifier: taskIdentifier
            )
        )
        let event = makeEvent(
            taskToken: taskToken,
            taskIdentifier: taskIdentifier,
            completedBytes: Int64(payload.count)
        )
        try journal.append(event)

        let drained = try E2eeBackgroundDownloadEventDrainer(
            store: store,
            fileStore: E2eeBackgroundDownloadFileStore(rootURL: directory),
            journal: journal
        ).drain()

        XCTAssertEqual(drained, 0)
        XCTAssertEqual(try journal.readAll(), [event])
        XCTAssertEqual(try store.record(taskToken: taskToken)?.phase, .scheduled)
    }

    func testDownloadProgressCannotRegressAcrossCallbacks() throws {
        let payload = Data(repeating: 0x5a, count: 100)
        let taskToken = UUID().uuidString
        let taskIdentifier = 44
        let store = E2eeDurableBackgroundDownloadStore(rootURL: directory)
        let journal = makeJournal()
        try store.insert(
            makeRecord(
                payload: payload,
                taskToken: taskToken,
                taskIdentifier: taskIdentifier
            )
        )
        try journal.append(
            makeEvent(
                taskToken: taskToken,
                taskIdentifier: taskIdentifier,
                kind: .progress,
                completedBytes: 70
            )
        )
        try journal.append(
            makeEvent(
                taskToken: taskToken,
                taskIdentifier: taskIdentifier,
                kind: .progress,
                completedBytes: 20
            )
        )

        XCTAssertEqual(
            try E2eeBackgroundDownloadEventDrainer(
                store: store,
                fileStore: E2eeBackgroundDownloadFileStore(rootURL: directory),
                journal: journal
            ).drain(),
            2
        )
        XCTAssertEqual(try store.record(taskToken: taskToken)?.completedCiphertextBytes, 70)
    }

    func testInsertOrExistingReusesSameLogicalDownloadAtomically() throws {
        let payload = Data("canonical ciphertext".utf8)
        let store = E2eeDurableBackgroundDownloadStore(rootURL: directory)
        let logicalIdentity = (
            accountId: "account-a",
            cid: "messaging:shared-channel",
            attachmentId: UUID().uuidString,
            assetId: UUID().uuidString
        )
        let first = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 45,
            accountId: logicalIdentity.accountId,
            cid: logicalIdentity.cid,
            attachmentId: logicalIdentity.attachmentId,
            assetId: logicalIdentity.assetId,
            now: Date(timeIntervalSince1970: 1)
        )
        let duplicate = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 46,
            accountId: logicalIdentity.accountId,
            cid: logicalIdentity.cid,
            attachmentId: logicalIdentity.attachmentId,
            assetId: logicalIdentity.assetId,
            now: Date(timeIntervalSince1970: 2)
        )

        let inserted = try store.insertOrExisting(first)
        let reused = try store.insertOrExisting(duplicate)

        XCTAssertTrue(inserted.inserted)
        XCTAssertEqual(inserted.record, first)
        XCTAssertFalse(reused.inserted)
        XCTAssertEqual(reused.record.downloadId, first.downloadId)
        XCTAssertEqual(reused.record.taskToken, first.taskToken)
        XCTAssertEqual(try store.hydrate(), [first])
    }

    func testAccountScopedRecordsNeverReturnAnotherAccountsDownload() throws {
        let payload = Data("canonical ciphertext".utf8)
        let store = E2eeDurableBackgroundDownloadStore(rootURL: directory)
        let accountA = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 47,
            accountId: "account-a"
        )
        let accountB = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 48,
            accountId: "account-b"
        )
        try store.insert(accountA)
        try store.insert(accountB)

        let accountARecords = try store.records(accountId: "account-a")
        let accountBRecords = try store.records(accountId: "account-b")
        XCTAssertEqual(accountARecords.map(\.downloadId), [accountA.downloadId])
        XCTAssertEqual(accountARecords.map(\.accountId), ["account-a"])
        XCTAssertEqual(accountBRecords.map(\.downloadId), [accountB.downloadId])
        XCTAssertEqual(accountBRecords.map(\.accountId), ["account-b"])
        XCTAssertTrue(try store.records(accountId: "account-c").isEmpty)
    }

    func testExactAssetRecordsDoNotReturnSiblingAssetOrAnotherAccount() throws {
        let payload = Data("canonical ciphertext".utf8)
        let store = E2eeDurableBackgroundDownloadStore(rootURL: directory)
        let cid = "messaging:\(UUID().uuidString)"
        let attachmentId = UUID().uuidString
        let assetId = UUID().uuidString
        let exact = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 49,
            accountId: "account-a",
            cid: cid,
            attachmentId: attachmentId,
            assetId: assetId
        )
        let siblingAsset = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 50,
            accountId: "account-a",
            cid: cid,
            attachmentId: attachmentId,
            assetId: UUID().uuidString
        )
        let otherAccount = makeRecord(
            payload: payload,
            taskToken: UUID().uuidString,
            taskIdentifier: 51,
            accountId: "account-b",
            cid: cid,
            attachmentId: attachmentId,
            assetId: assetId
        )
        try store.insert(exact)
        try store.insert(siblingAsset)
        try store.insert(otherAccount)

        let records = try store.records(
            accountId: "account-a",
            cid: cid,
            attachmentId: attachmentId.uppercased(),
            assetId: assetId.uppercased()
        )

        XCTAssertEqual(records.map(\.downloadId), [exact.downloadId])
    }

    private func makeJournal() -> BackgroundTransferEventJournal {
        BackgroundTransferEventJournal(
            url: directory.appendingPathComponent("callbacks/events.bin")
        )
    }

    private func makeEvent(
        taskToken: String,
        taskIdentifier: Int,
        kind: BackgroundTransferEventKind = .completion,
        completedBytes: Int64 = 24
    ) -> BackgroundTransferEvent {
        BackgroundTransferEvent(
            taskToken: taskToken,
            taskIdentifier: taskIdentifier,
            operation: .download,
            kind: kind,
            completedBytes: completedBytes,
            totalBytes: max(completedBytes, 100),
            httpStatus: kind == .completion ? 200 : nil,
            eTag: nil,
            error: .none
        )
    }

    private func makeRecord(
        payload: Data,
        taskToken: String,
        taskIdentifier: Int,
        accountId: String = "account-a",
        cid: String = "messaging:\(UUID().uuidString)",
        attachmentId: String = UUID().uuidString,
        assetId: String = UUID().uuidString,
        now: Date = Date()
    ) -> E2eeDurableBackgroundDownload {
        E2eeDurableBackgroundDownload(
            accountId: accountId,
            cid: cid,
            attachmentId: attachmentId,
            assetId: assetId,
            taskToken: taskToken,
            taskIdentifier: taskIdentifier,
            expectedCiphertextSize: Int64(payload.count),
            expectedCiphertextSha256: SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }
                .joined(),
            now: now
        )
    }
}
