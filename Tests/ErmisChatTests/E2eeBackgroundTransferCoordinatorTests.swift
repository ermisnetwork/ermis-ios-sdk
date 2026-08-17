//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeBackgroundTransferCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeBackgroundTransferCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testSessionIdentifierIsStablePerAppEnvironmentAndNotPerAccount() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://chat.example.test/v1"))
        let first = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.test-app",
            endpoint: endpoint,
            applicationGroupIdentifier: "group.network.ermis.test"
        )
        let second = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.test-app",
            endpoint: endpoint,
            applicationGroupIdentifier: "group.network.ermis.test"
        )
        let otherEnvironment = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.test-app",
            endpoint: try XCTUnwrap(URL(string: "https://staging.example.test/v1")),
            applicationGroupIdentifier: "group.network.ermis.test"
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, otherEnvironment)
        XCTAssertFalse(first.identifier.contains("account"))
        XCTAssertFalse(first.identifier.contains("chat.example.test"))
    }

    func testHostCompletionHandlerHasExactlyOneOwnerAndRunsAfterReconcile() throws {
        let coordinator = try makeCoordinator()
        let handled = expectation(description: "host completion")
        let duplicate = expectation(description: "duplicate completion")
        duplicate.isInverted = true

        XCTAssertEqual(
            coordinator.handleEventsForBackgroundURLSession(
                identifier: coordinator.sessionIdentifier,
                completionHandler: { handled.fulfill() }
            ),
            .accepted
        )
        XCTAssertEqual(
            coordinator.handleEventsForBackgroundURLSession(
                identifier: coordinator.sessionIdentifier,
                completionHandler: { duplicate.fulfill() }
            ),
            .completionHandlerAlreadyOwned
        )

        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)

        wait(for: [handled, duplicate], timeout: 2)
    }

    func testUnknownSessionIdentifierDoesNotConsumeHostHandler() throws {
        let coordinator = try makeCoordinator()
        let completion = expectation(description: "unsupported handler")
        completion.isInverted = true

        XCTAssertEqual(
            coordinator.handleEventsForBackgroundURLSession(
                identifier: "network.ermis.e2ee.transfer.unsupported",
                completionHandler: { completion.fulfill() }
            ),
            .unsupportedSessionIdentifier
        )

        wait(for: [completion], timeout: 0.1)
    }

    func testDurableAttemptLookupIsScopedByMessageAndAccount() throws {
        let coordinator = try makeCoordinator()
        let messageId = UUID().uuidString
        let accountId = "account-a"
        let attempt = PendingE2eeTransferAttempt(
            accountId: accountId,
            messageId: messageId,
            cid: "messaging:\(UUID().uuidString)",
            phase: .finalizing
        )
        try coordinator.store.insert(attempt)

        XCTAssertTrue(
            coordinator.hasDurableAttempt(messageId: messageId, accountId: accountId)
        )
        XCTAssertFalse(
            coordinator.hasDurableAttempt(messageId: messageId, accountId: "account-b")
        )
        XCTAssertFalse(
            coordinator.hasDurableAttempt(messageId: UUID().uuidString, accountId: accountId)
        )
    }

    func testScheduleBackgroundDownloadPersistsOpaqueMappingBeforeTaskRuns() throws {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let coordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [HoldingUploadURLProtocol.self]
                return configuration
            }
        )
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://download.example.test/ciphertext"))
        )
        request.httpMethod = "GET"

        let scheduled = try coordinator.scheduleBackgroundDownload(
            accountId: "account-a",
            cid: "messaging:\(UUID().uuidString)",
            attachmentId: UUID().uuidString,
            assetId: UUID().uuidString,
            request: request,
            expectedCiphertextSize: 128,
            expectedCiphertextSha256: String(repeating: "a", count: 64)
        )
        let durable = try XCTUnwrap(
            coordinator.backgroundDownloadStore.record(taskToken: scheduled.taskToken)
        )

        // The durable JSON round-trip can trim sub-millisecond `Date` precision. Assert the
        // correctness-critical mapping instead of relying on exact timestamp equality.
        XCTAssertEqual(durable.downloadId, scheduled.downloadId)
        XCTAssertEqual(durable.accountId, scheduled.accountId)
        XCTAssertEqual(durable.cid, scheduled.cid)
        XCTAssertEqual(durable.attachmentId, scheduled.attachmentId)
        XCTAssertEqual(durable.assetId, scheduled.assetId)
        XCTAssertEqual(durable.taskToken, scheduled.taskToken)
        XCTAssertEqual(durable.taskIdentifier, scheduled.taskIdentifier)
        XCTAssertEqual(durable.expectedCiphertextSize, scheduled.expectedCiphertextSize)
        XCTAssertEqual(durable.expectedCiphertextSha256, scheduled.expectedCiphertextSha256)
        XCTAssertEqual(durable.completedCiphertextBytes, scheduled.completedCiphertextBytes)
        XCTAssertEqual(durable.phase, scheduled.phase)
        XCTAssertEqual(durable.fixedError, scheduled.fixedError)
        XCTAssertEqual(durable.verifiedCiphertextURL, scheduled.verifiedCiphertextURL)
        XCTAssertEqual(durable.phase, .scheduled)
        XCTAssertNotNil(durable.taskIdentifier)
        XCTAssertNotEqual(durable.taskToken, durable.accountId)
        XCTAssertNotEqual(durable.taskToken, durable.attachmentId)
        XCTAssertNotEqual(durable.taskToken, durable.assetId)
    }

    func testCancelBackgroundDownloadCancelsOnlyExactAsset() throws {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let coordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [HoldingUploadURLProtocol.self]
                return configuration
            }
        )
        let accountId = "account-a"
        let cid = "messaging:\(UUID().uuidString)"
        let attachmentId = UUID().uuidString
        let targetAssetId = UUID().uuidString
        let siblingAssetId = UUID().uuidString
        var targetRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://download.example.test/target"))
        )
        targetRequest.httpMethod = "GET"
        var siblingRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://download.example.test/sibling"))
        )
        siblingRequest.httpMethod = "GET"
        let target = try coordinator.scheduleBackgroundDownload(
            accountId: accountId,
            cid: cid,
            attachmentId: attachmentId,
            assetId: targetAssetId,
            request: targetRequest,
            expectedCiphertextSize: 128,
            expectedCiphertextSha256: String(repeating: "a", count: 64)
        )
        let sibling = try coordinator.scheduleBackgroundDownload(
            accountId: accountId,
            cid: cid,
            attachmentId: attachmentId,
            assetId: siblingAssetId,
            request: siblingRequest,
            expectedCiphertextSize: 256,
            expectedCiphertextSha256: String(repeating: "b", count: 64)
        )

        let canceled = expectation(description: "exact background download canceled")
        coordinator.cancelBackgroundDownload(
            accountId: accountId,
            cid: cid,
            attachmentId: attachmentId,
            assetId: targetAssetId
        ) { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected exact cancel failure: \(error)")
            }
            canceled.fulfill()
        }
        wait(for: [canceled], timeout: 2)

        let canceledTarget = try XCTUnwrap(
            coordinator.backgroundDownloadStore.record(downloadId: target.downloadId)
        )
        let untouchedSibling = try XCTUnwrap(
            coordinator.backgroundDownloadStore.record(downloadId: sibling.downloadId)
        )
        XCTAssertEqual(canceledTarget.phase, .canceled)
        XCTAssertEqual(canceledTarget.fixedError, .canceled)
        XCTAssertNil(canceledTarget.verifiedCiphertextURL)
        XCTAssertNotEqual(untouchedSibling.phase, .canceled)
        XCTAssertNil(untouchedSibling.fixedError)

        let cleanup = expectation(description: "remaining background task cleanup")
        coordinator.cancelTasks(accountId: accountId) { _ in cleanup.fulfill() }
        wait(for: [cleanup], timeout: 2)
    }

    func testSinglePutRejectsFileOutsideCanonicalCiphertextStaging() throws {
        let coordinator = try makeCoordinator()
        let source = directory.appendingPathComponent("plaintext.txt")
        try Data("plaintext must never be uploaded".utf8).write(to: source)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://upload.example.test/object")))
        request.httpMethod = "PUT"

        XCTAssertThrowsError(
            try coordinator.scheduleSinglePut(
                attemptId: UUID().uuidString,
                assetId: UUID().uuidString,
                request: request,
                fileURL: source
            )
        ) { error in
            XCTAssertEqual(
                error as? E2eeBackgroundTransferCoordinatorError,
                .nonCanonicalUploadSource
            )
        }
    }

    func testReconcileTwoActiveSinglePutAssetsDoesNotFailStateValidation() throws {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let scopedRoot = directory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(descriptor.storageNamespace, isDirectory: true)
        let stagingStore = E2eeAttachmentStagingStore(
            rootURL: scopedRoot,
            capacityProvider: BackgroundFixedCapacityProvider(capacity: UInt64.max)
        )
        try stagingStore.prepareEncryptedDirectories()
        let originalURL = stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        let previewURL = stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        try Data(repeating: 1, count: 128).write(to: originalURL)
        try Data(repeating: 2, count: 32).write(to: previewURL)

        let originalId = UUID().uuidString
        let previewId = UUID().uuidString
        let logicalAttachmentId = UUID().uuidString
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .encrypting,
            totalBytes: 160
        )
        attempt.assets = [
            PendingE2eeAsset(
                attachmentId: logicalAttachmentId,
                assetId: originalId,
                kind: .original,
                sourceURL: nil,
                canonicalCiphertextURL: originalURL,
                ciphertextSize: 128,
                ciphertextSha256: String(repeating: "a", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                taskIdentifier: nil,
                taskToken: nil,
                parts: []
            ),
            PendingE2eeAsset(
                attachmentId: logicalAttachmentId,
                assetId: previewId,
                kind: .preview,
                sourceURL: nil,
                canonicalCiphertextURL: previewURL,
                ciphertextSize: 32,
                ciphertextSha256: String(repeating: "b", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                taskIdentifier: nil,
                taskToken: nil,
                parts: []
            )
        ]
        let durableStore = E2eeDurableTransferStore(rootURL: scopedRoot)
        try durableStore.insert(attempt)
        let coordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [HoldingUploadURLProtocol.self]
                return configuration
            }
        )
        for (assetId, fileURL) in [(originalId, originalURL), (previewId, previewURL)] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://upload.example.test/\(assetId)")))
            request.httpMethod = "PUT"
            _ = try coordinator.scheduleSinglePut(
                attemptId: attempt.attemptId,
                assetId: assetId,
                request: request,
                fileURL: fileURL
            )
        }

        let reconciled = expectation(description: "single PUT assets reconciled")
        coordinator.reconcile { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected reconcile failure: \(error)")
            }
            reconciled.fulfill()
        }
        wait(for: [reconciled], timeout: 2)

        XCTAssertEqual(try durableStore.attempt(attemptId: attempt.attemptId).phase, .waitingForSystem)
    }

    func testTerminalCallbackAfterRetryableFailureDoesNotPoisonJournal() throws {
        let root = directory.appendingPathComponent("poison-journal", isDirectory: true)
        let durableStore = E2eeDurableTransferStore(rootURL: root)
        let journal = BackgroundTransferEventJournal(
            url: root.appendingPathComponent("callbacks.journal")
        )
        let token = UUID().uuidString
        let taskIdentifier = 42
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .failedRetryable,
            totalBytes: 9
        )
        attempt.failureReason = .backgroundTaskMissing
        attempt.assets = [
            PendingE2eeAsset(
                attachmentId: UUID().uuidString,
                assetId: UUID().uuidString,
                kind: .original,
                sourceURL: nil,
                canonicalCiphertextURL: nil,
                ciphertextSize: 9,
                ciphertextSha256: String(repeating: "a", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                taskIdentifier: taskIdentifier,
                taskToken: token,
                parts: []
            )
        ]
        try durableStore.insert(attempt)
        try journal.append(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: taskIdentifier,
                completedBytes: 9,
                totalBytes: 9,
                httpStatus: 400,
                eTag: nil,
                error: .none
            )
        )

        let drainer = E2eeBackgroundTransferEventDrainer(store: durableStore, journal: journal)
        XCTAssertEqual(try drainer.drain(), 1)
        let updated = try durableStore.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(updated.phase, .failedTerminal)
        XCTAssertEqual(updated.failureReason, .invalidServerResponse)
        XCTAssertTrue(try journal.readAll().isEmpty)
    }

    func testResumeReconcilesThenSchedulesBoundedMultipartWindow() throws {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let scopedRoot = directory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(descriptor.storageNamespace, isDirectory: true)
        let stagingStore = E2eeAttachmentStagingStore(
            rootURL: scopedRoot,
            capacityProvider: BackgroundFixedCapacityProvider(capacity: UInt64.max)
        )
        try stagingStore.prepareEncryptedDirectories()
        let canonicalURL = stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        try Data((0..<50).map(UInt8.init)).write(to: canonicalURL)

        let assetId = UUID().uuidString
        let parts = try (1...5).map { number in
            PendingE2eeMultipartPart(
                number: number,
                offset: UInt64((number - 1) * 10),
                size: 10,
                putURL: try XCTUnwrap(
                    URL(string: "https://upload.example.test/part-\(number)")
                ),
                eTag: nil,
                taskIdentifier: nil,
                taskToken: nil,
                localFileURL: nil
            )
        }
        var asset = PendingE2eeAsset(
            attachmentId: UUID().uuidString,
            assetId: assetId,
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: canonicalURL,
            ciphertextSize: 50,
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: nil,
            uploadMode: .multipart,
            uploadExpiresAt: Date().addingTimeInterval(600),
            taskIdentifier: nil,
            taskToken: nil,
            parts: parts
        )
        asset.multipartPartSize = 10
        asset.multipartUploadId = "opaque-upload"
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .uploading,
            totalBytes: 50
        )
        attempt.assets = [asset]
        let durableStore = E2eeDurableTransferStore(rootURL: scopedRoot)
        try durableStore.insert(attempt)

        let coordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [HoldingUploadURLProtocol.self]
                return configuration
            }
        )
        let resumed = expectation(description: "multipart resumed")
        coordinator.resumeMultipartUploads { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected resume failure: \(error)")
            }
            resumed.fulfill()
        }

        wait(for: [resumed], timeout: 2)
        let updated = try XCTUnwrap(durableStore.hydrate().first)
        let updatedParts = try XCTUnwrap(updated.assets.first?.parts)
        XCTAssertEqual(updatedParts.filter { $0.taskToken != nil }.count, 3)
        XCTAssertEqual(updatedParts.compactMap(\.localFileURL).count, 4)

        let canceled = expectation(description: "multipart canceled")
        coordinator.cancelTasks(accountId: "account-a") { _ in canceled.fulfill() }
        wait(for: [canceled], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        let canceledAttempt = try XCTUnwrap(durableStore.hydrate().first)
        XCTAssertEqual(canceledAttempt.phase, .canceled)
        XCTAssertTrue(canceledAttempt.assets.allSatisfy { $0.canonicalCiphertextURL == nil })
        XCTAssertTrue(canceledAttempt.assets.flatMap(\.parts).allSatisfy {
            $0.localFileURL == nil && $0.taskToken == nil
        })
    }

    func testExpiredMultipartAttemptRemovesPartsButRetainsCanonicalCiphertext() throws {
        let context = try makePersistentCoordinatorContext()
        let canonicalURL = context.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        try Data((0..<30).map(UInt8.init)).write(to: canonicalURL)

        let assetId = UUID().uuidString
        let attemptId = UUID().uuidString
        let partURL = try context.stagingStore.multipartPartURL(
            attemptId: attemptId,
            assetId: assetId,
            partNumber: 1
        )
        try Data((0..<10).map(UInt8.init)).write(to: partURL)
        var asset = PendingE2eeAsset(
            attachmentId: UUID().uuidString,
            assetId: assetId,
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: canonicalURL,
            ciphertextSize: 30,
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: nil,
            uploadMode: .multipart,
            uploadExpiresAt: Date().addingTimeInterval(-1),
            taskIdentifier: nil,
            taskToken: nil,
            parts: [
                PendingE2eeMultipartPart(
                    number: 1,
                    offset: 0,
                    size: 10,
                    putURL: try XCTUnwrap(URL(string: "https://upload.example.test/part-1")),
                    eTag: nil,
                    taskIdentifier: nil,
                    taskToken: nil,
                    localFileURL: partURL
                ),
                PendingE2eeMultipartPart(
                    number: 2,
                    offset: 10,
                    size: 10,
                    putURL: try XCTUnwrap(URL(string: "https://upload.example.test/part-2")),
                    eTag: nil,
                    taskIdentifier: nil,
                    taskToken: nil,
                    localFileURL: nil
                ),
                PendingE2eeMultipartPart(
                    number: 3,
                    offset: 20,
                    size: 10,
                    putURL: try XCTUnwrap(URL(string: "https://upload.example.test/part-3")),
                    eTag: nil,
                    taskIdentifier: nil,
                    taskToken: nil,
                    localFileURL: nil
                )
            ]
        )
        asset.multipartPartSize = 10
        asset.multipartUploadId = "opaque-upload"
        var attempt = PendingE2eeTransferAttempt(
            attemptId: attemptId,
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .uploading,
            totalBytes: 30
        )
        attempt.assets = [asset]
        try context.durableStore.insert(attempt)

        let reconciled = expectation(description: "expired attempt reconciled")
        context.coordinator.reconcile { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected reconcile failure: \(error)")
            }
            reconciled.fulfill()
        }
        wait(for: [reconciled], timeout: 2)

        let updated = try XCTUnwrap(context.durableStore.hydrate().first)
        XCTAssertEqual(updated.phase, .failedRetryable)
        XCTAssertEqual(updated.failureReason, .uploadExpired)
        XCTAssertEqual(updated.assets.first?.canonicalCiphertextURL, canonicalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertTrue(updated.assets.flatMap(\.parts).allSatisfy {
            $0.localFileURL == nil && $0.taskIdentifier == nil && $0.taskToken == nil
        })
    }

    func testAccountScopedCancelDoesNotAffectOtherAccountTransfer() throws {
        let context = try makePersistentCoordinatorContext()
        let accountACanonical = context.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        let accountBCanonical = context.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        try Data("account-a".utf8).write(to: accountACanonical)
        try Data("account-b".utf8).write(to: accountBCanonical)

        let accountA = makeSinglePutAttempt(accountId: "account-a", canonicalURL: accountACanonical)
        let accountB = makeSinglePutAttempt(accountId: "account-b", canonicalURL: accountBCanonical)
        try context.durableStore.insert(accountA)
        try context.durableStore.insert(accountB)

        let canceled = expectation(description: "account A canceled")
        context.coordinator.cancelTasks(accountId: "account-a") { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected scoped cancel failure: \(error)")
            }
            canceled.fulfill()
        }
        wait(for: [canceled], timeout: 2)

        let attempts = try context.durableStore.hydrate()
        XCTAssertEqual(attempts.first(where: { $0.accountId == "account-a" })?.phase, .canceled)
        XCTAssertEqual(attempts.first(where: { $0.accountId == "account-b" })?.phase, .uploading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountACanonical.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountBCanonical.path))
    }

    func testAuthoritativeMessageConfirmationCleansOnlyMatchingAccountStaging() throws {
        let context = try makePersistentCoordinatorContext()
        let messageId = UUID().uuidString
        let accountACanonical = context.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        let accountBCanonical = context.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        try Data("account-a".utf8).write(to: accountACanonical)
        try Data("account-b".utf8).write(to: accountBCanonical)
        try context.durableStore.insert(makeSinglePutAttempt(
            accountId: "account-a",
            canonicalURL: accountACanonical,
            messageId: messageId,
            phase: .sending
        ))
        try context.durableStore.insert(makeSinglePutAttempt(
            accountId: "account-b",
            canonicalURL: accountBCanonical,
            messageId: messageId,
            phase: .sending
        ))

        let confirmed = expectation(description: "authoritative response applied")
        context.coordinator.confirmMessage(messageId: messageId, accountId: "account-a") { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected confirmation failure: \(error)")
            }
            confirmed.fulfill()
        }
        wait(for: [confirmed], timeout: 2)

        let attempts = try context.durableStore.hydrate()
        let accountA = try XCTUnwrap(attempts.first(where: { $0.accountId == "account-a" }))
        let accountB = try XCTUnwrap(attempts.first(where: { $0.accountId == "account-b" }))
        XCTAssertEqual(accountA.phase, .confirmed)
        XCTAssertNil(accountA.assets.first?.canonicalCiphertextURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountACanonical.path))
        XCTAssertEqual(accountB.phase, .sending)
        XCTAssertEqual(accountB.assets.first?.canonicalCiphertextURL, accountBCanonical)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountBCanonical.path))
    }

    func testProgressCallbackIsDrainedAndPublishedToTransferObserver() throws {
        let context = try makePersistentCoordinatorContext()
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://upload.example.test/object"))
        )
        let task = URLSession.shared.uploadTask(with: request, from: Data())
        let token = UUID().uuidString
        task.taskDescription = token

        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:\(UUID().uuidString)",
            phase: .uploading,
            totalBytes: 10
        )
        attempt.assets = [
            PendingE2eeAsset(
                attachmentId: UUID().uuidString,
                assetId: UUID().uuidString,
                kind: .original,
                sourceURL: nil,
                canonicalCiphertextURL: nil,
                ciphertextSize: 10,
                ciphertextSha256: String(repeating: "a", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                completedBytes: 0,
                taskIdentifier: task.taskIdentifier,
                taskToken: token,
                parts: []
            )
        ]
        try context.durableStore.insert(attempt)

        let published = expectation(description: "durable upload progress published")
        let observerId = context.coordinator.addTransferObserver { snapshot in
            if snapshot.attemptId == attempt.attemptId,
               snapshot.publicProgress.fractionCompleted == 0.5 {
                published.fulfill()
            }
        }
        context.coordinator.urlSession(
            .shared,
            task: task,
            didSendBodyData: 5,
            totalBytesSent: 5,
            totalBytesExpectedToSend: 10
        )

        wait(for: [published], timeout: 2)
        context.coordinator.removeTransferObserver(observerId)
        let updated = try context.durableStore.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(updated.completedBytes, 5)
        XCTAssertEqual(updated.assets.first?.completedBytes, 5)
        task.cancel()
    }

    func testProgressJournalThrottlePersistsAtMostFivePercentCheckpoints() {
        var throttle = E2eeTransferProgressJournalThrottle()
        let token = UUID().uuidString

        XCTAssertFalse(throttle.shouldPersist(taskToken: token, completedBytes: 1, totalBytes: 100))
        XCTAssertTrue(throttle.shouldPersist(taskToken: token, completedBytes: 5, totalBytes: 100))
        XCTAssertFalse(throttle.shouldPersist(taskToken: token, completedBytes: 9, totalBytes: 100))
        XCTAssertTrue(throttle.shouldPersist(taskToken: token, completedBytes: 10, totalBytes: 100))
        XCTAssertFalse(throttle.shouldPersist(taskToken: token, completedBytes: 8, totalBytes: 100))
        XCTAssertTrue(throttle.shouldPersist(taskToken: token, completedBytes: 100, totalBytes: 100))

        throttle.remove(taskToken: token)
        XCTAssertTrue(throttle.shouldPersist(taskToken: token, completedBytes: 5, totalBytes: 100))
    }

    func testBodySentReconcileGateSchedulesOnceAndCompletionCancelsWatchdog() {
        var gate = E2eeBodySentReconcileGate()
        let token = UUID().uuidString

        XCTAssertTrue(gate.schedule(taskToken: token))
        XCTAssertFalse(gate.schedule(taskToken: token))
        gate.cancel(taskToken: token)
        XCTAssertFalse(gate.consume(taskToken: token))
    }

    func testBodySentReconcileGateConsumesMissingCompletionWatchdogOnce() {
        var gate = E2eeBodySentReconcileGate()
        let token = UUID().uuidString

        XCTAssertTrue(gate.schedule(taskToken: token))
        XCTAssertTrue(gate.consume(taskToken: token))
        XCTAssertFalse(gate.consume(taskToken: token))
    }

    func testReconcileRequestDuringActivePassForcesTrailingJournalDrainPass() {
        var gate = E2eeReconcilePassGate()

        XCTAssertTrue(gate.requestPass())
        XCTAssertTrue(gate.isRunning)

        // Original and preview PUT callbacks can arrive in this order while the first pass has
        // already drained its journal. The second request must not be treated as handled by that
        // first pass.
        XCTAssertFalse(gate.requestPass())
        XCTAssertTrue(gate.finishPassAndShouldRunAgain())
        XCTAssertTrue(gate.isRunning)

        XCTAssertFalse(gate.finishPassAndShouldRunAgain())
        XCTAssertFalse(gate.isRunning)
    }

    func testManyReconcileRequestsDuringActivePassNeedOneTrailingPass() {
        var gate = E2eeReconcilePassGate()

        XCTAssertTrue(gate.requestPass())
        XCTAssertFalse(gate.requestPass())
        XCTAssertFalse(gate.requestPass())
        XCTAssertTrue(gate.finishPassAndShouldRunAgain())
        XCTAssertFalse(gate.finishPassAndShouldRunAgain())
    }

    private func makePersistentCoordinatorContext() throws -> (
        coordinator: E2eeBackgroundTransferCoordinator,
        stagingStore: E2eeAttachmentStagingStore,
        durableStore: E2eeDurableTransferStore
    ) {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let scopedRoot = directory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(descriptor.storageNamespace, isDirectory: true)
        let stagingStore = E2eeAttachmentStagingStore(
            rootURL: scopedRoot,
            capacityProvider: BackgroundFixedCapacityProvider(capacity: UInt64.max)
        )
        try stagingStore.prepareEncryptedDirectories()
        return (
            E2eeBackgroundTransferCoordinator(
                descriptor: descriptor,
                rootURL: directory,
                applicationGroupIdentifier: nil,
                sessionConfigurationBuilder: { _, _ in .ephemeral }
            ),
            stagingStore,
            E2eeDurableTransferStore(rootURL: scopedRoot)
        )
    }

    private func makeSinglePutAttempt(
        accountId: String,
        canonicalURL: URL,
        messageId: String = UUID().uuidString,
        phase: E2eeTransferPhase = .uploading
    ) -> PendingE2eeTransferAttempt {
        var attempt = PendingE2eeTransferAttempt(
            accountId: accountId,
            messageId: messageId,
            cid: "messaging:\(UUID().uuidString)",
            phase: phase,
            totalBytes: 9
        )
        attempt.assets = [
            PendingE2eeAsset(
                attachmentId: UUID().uuidString,
                assetId: UUID().uuidString,
                kind: .original,
                sourceURL: nil,
                canonicalCiphertextURL: canonicalURL,
                ciphertextSize: 9,
                ciphertextSha256: String(repeating: "a", count: 64),
                sealedSecret: nil,
                uploadMode: .singlePut,
                uploadExpiresAt: Date().addingTimeInterval(600),
                taskIdentifier: nil,
                taskToken: nil,
                parts: []
            )
        ]
        return attempt
    }

    private func makeCoordinator() throws -> E2eeBackgroundTransferCoordinator {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        return E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in .ephemeral }
        )
    }
}

private final class HoldingUploadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}

private struct BackgroundFixedCapacityProvider: E2eeAttachmentCapacityProviding {
    let capacity: UInt64

    func availableCapacity(at url: URL) throws -> UInt64 { capacity }
}
