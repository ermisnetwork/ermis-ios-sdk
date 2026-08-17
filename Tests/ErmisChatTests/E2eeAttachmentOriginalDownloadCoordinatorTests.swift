//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChat
import CoreData
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

    func testAuthenticatedOriginalUsesExactFreshGrantAndReleasesPlaintextOnlyAfterVerification() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let phases = LockedDownloadPhases()
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport
        )

        let lease = try await coordinator.localOriginalLease(for: fixture.attachment) {
            phases.append($0.phase)
        }
        defer { lease.release() }

        XCTAssertEqual(try Data(contentsOf: lease.localURL), fixture.plaintext)
        XCTAssertEqual(
            grants.values,
            [
                .init(
                    cid: fixture.cid,
                    attachmentId: fixture.manifest.attachmentId,
                    assetId: fixture.original.assetId
                )
            ]
        )
        XCTAssertEqual(transport.callCount, 1)
        try await waitUntil { phases.values.contains(.decrypting) }
        let values = phases.values
        XCTAssertLessThan(
            try XCTUnwrap(values.firstIndex(of: .verifying)),
            try XCTUnwrap(values.firstIndex(of: .decrypting))
        )
    }

    func testUnauthorizedObjectStoreResponseRenewsGrantOnceAndRestartsFullGet() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [403, 200]
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport
        )

        let lease = try await coordinator.localOriginalLease(for: fixture.attachment) { _ in }
        defer { lease.release() }

        XCTAssertEqual(try Data(contentsOf: lease.localURL), fixture.plaintext)
        XCTAssertEqual(grants.values.count, 2)
        XCTAssertEqual(Set(grants.values.map(\.attachmentId)), [fixture.manifest.attachmentId])
        XCTAssertEqual(Set(grants.values.map(\.assetId)), [fixture.original.assetId])
        XCTAssertEqual(transport.callCount, 2)
        XCTAssertNotEqual(transport.requestURLs.first, transport.requestURLs.last)
    }

    func testCipherHashMismatchNeverAdvancesToDecryptOrPublishesPlaintext() async throws {
        let fixture = try makeDownloadFixture(cipherHashOverride: String(repeating: "0", count: 64))
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let phases = LockedDownloadPhases()
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport
        )

        do {
            _ = try await coordinator.localOriginalLease(for: fixture.attachment) {
                phases.append($0.phase)
            }
            XCTFail("A globally mismatched ciphertext must never expose plaintext")
        } catch let error as E2eeAttachmentOriginalDownloadError {
            guard case .cipherHashMismatch = error else {
                return XCTFail("Expected cipherHashMismatch, got \(error)")
            }
        }

        try await waitUntil { phases.values.contains(.verifying) }
        XCTAssertFalse(phases.values.contains(.decrypting))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.playbackDirectory.path).isEmpty)
        XCTAssertEqual(grants.values.count, 1)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testPlaintextSurvivesUntilLastViewerOrExportLeaseReleases() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport
        )

        let viewerLease = try await coordinator.localOriginalLease(for: fixture.attachment) { _ in }
        let exportLease = try await coordinator.localOriginalLease(for: fixture.attachment) { _ in }
        let plaintextURL = viewerLease.localURL

        XCTAssertEqual(exportLease.localURL, plaintextURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plaintextURL.path))
        XCTAssertEqual(transport.callCount, 1)

        viewerLease.release()
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plaintextURL.path),
            "Closing one viewer must not invalidate an active Save/Share consumer"
        )

        exportLease.release()
        try await waitUntil {
            !FileManager.default.fileExists(atPath: plaintextURL.path)
        }
    }

    func testShutdownCancelsConsumersAndRemovesProcessPlaintext() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport
        )

        let lease = try await coordinator.localOriginalLease(for: fixture.attachment) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.localURL.path))

        await coordinator.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.playbackDirectory.path))
        lease.release()
    }

    func testWaitingForUnlockRetainsVerifiedCiphertextAndCreatesNoPlaintext() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let phases = LockedDownloadPhases()
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport,
            plaintextPermissionWaiter: { ciphertextSize, progress in
                progress(.init(
                    phase: .waitingForUnlock,
                    completedCiphertextBytes: ciphertextSize,
                    totalCiphertextBytes: ciphertextSize
                ))
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let request = Task {
            try await coordinator.localOriginalLease(for: fixture.attachment) {
                phases.append($0.phase)
            }
        }

        try await waitUntil { phases.values.contains(.waitingForUnlock) }

        let ciphertextEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.ciphertextDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(ciphertextEntries.filter { $0.pathExtension == "cipher" }.count, 1)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.playbackDirectory.path).isEmpty,
            "Protected-data wait must not publish plaintext or a plaintext partial"
        )

        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Canceling a locked-device request must stop the foreground consumer")
        } catch is CancellationError {
            // Expected. The verified ciphertext remains available for the post-unlock retry.
        }

        let retainedEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.ciphertextDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(retainedEntries.filter { $0.pathExtension == "cipher" }.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.playbackDirectory.path).isEmpty)
    }

    func testDurableCiphertextIsConsumedOnlyAfterAuthenticatedPlaintextIsPublished() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let providerCalls = LockedCounter()
        let consumeCalls = LockedCounter()
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport,
            durableCiphertextProvider: { _ in
                providerCalls.increment()
                return .init(
                    localURL: fixture.canonicalCiphertextURL,
                    consumeHandler: { consumeCalls.increment() }
                )
            }
        )

        let lease = try await coordinator.localOriginalLease(for: fixture.attachment) { _ in }
        defer { lease.release() }

        XCTAssertEqual(try Data(contentsOf: lease.localURL), fixture.plaintext)
        XCTAssertEqual(providerCalls.value, 1)
        XCTAssertEqual(consumeCalls.value, 1)
        XCTAssertTrue(grants.values.isEmpty)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testViewerDetachWhileWaitingForUnlockDoesNotConsumeDurableCiphertext() async throws {
        let fixture = try makeDownloadFixture()
        defer { fixture.cleanup() }
        let grants = LockedGrantRequests()
        let transport = CiphertextTransport(
            sourceURL: fixture.canonicalCiphertextURL,
            outputDirectory: fixture.root,
            statuses: [200]
        )
        let phases = LockedDownloadPhases()
        let consumeCalls = LockedCounter()
        let coordinator = makeCoordinator(
            fixture: fixture,
            grants: grants,
            transport: transport,
            durableCiphertextProvider: { _ in
                .init(
                    localURL: fixture.canonicalCiphertextURL,
                    consumeHandler: { consumeCalls.increment() }
                )
            },
            plaintextPermissionWaiter: { ciphertextSize, progress in
                progress(.init(
                    phase: .waitingForUnlock,
                    completedCiphertextBytes: ciphertextSize,
                    totalCiphertextBytes: ciphertextSize
                ))
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let request = Task {
            try await coordinator.localOriginalLease(for: fixture.attachment) {
                phases.append($0.phase)
            }
        }

        try await waitUntil { phases.values.contains(.waitingForUnlock) }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Detaching the viewer must cancel only its waiter")
        } catch is CancellationError {
            // Expected. The durable verified ciphertext remains owned by the transfer layer.
        }

        XCTAssertEqual(consumeCalls.value, 0)
        XCTAssertTrue(grants.values.isEmpty)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.playbackDirectory.path).isEmpty)
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

    private func makeCoordinator(
        fixture: DownloadFixture,
        grants: LockedGrantRequests,
        transport: CiphertextTransport,
        durableCiphertextProvider: E2eeAttachmentOriginalDownloadCoordinator.DurableCiphertextProvider? = nil,
        plaintextPermissionWaiter: @escaping E2eeAttachmentOriginalDownloadCoordinator.PlaintextPermissionWaiter = { _, _ in }
    ) -> E2eeAttachmentOriginalDownloadCoordinator {
        E2eeAttachmentOriginalDownloadCoordinator(
            database: fixture.database,
            ciphertextDirectory: fixture.ciphertextDirectory,
            playbackDirectory: fixture.playbackDirectory,
            grantURLProvider: { cid, attachmentId, assetId in
                let sequence = grants.append(
                    .init(cid: cid, attachmentId: attachmentId, assetId: assetId)
                )
                return URL(string: "https://object.example.test/grant-\(sequence)")!
            },
            ciphertextDownloader: { input in
                try transport.download(
                    request: input.request,
                    expectedBytes: input.expectedCiphertextBytes,
                    progress: input.progress
                )
            },
            durableCiphertextProvider: durableCiphertextProvider,
            plaintextPermissionWaiter: plaintextPermissionWaiter
        )
    }

    private func makeDownloadFixture(cipherHashOverride: String? = nil) throws -> DownloadFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("E2eeOriginalIntegration-\(UUID().uuidString)", isDirectory: true)
        let ciphertextDirectory = root.appendingPathComponent("cipher-staging", isDirectory: true)
        let playbackDirectory = root.appendingPathComponent("playback", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ciphertextDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: playbackDirectory, withIntermediateDirectories: true)

        let plaintext = Data((0..<300_000).map { UInt8($0 % 251) })
        let plaintextURL = root.appendingPathComponent("source.bin")
        let canonicalCiphertextURL = root.appendingPathComponent("canonical.cipher")
        try plaintext.write(to: plaintextURL)
        let contentKey = Data(repeating: 0x17, count: E2eeAttachmentFrameCryptoV1.keySize)
        let noncePrefix = Data(repeating: 0x2A, count: E2eeAttachmentFrameCryptoV1.noncePrefixSize)
        let encrypted = try E2eeAttachmentFrameCryptoV1.encryptFile(
            at: plaintextURL,
            to: canonicalCiphertextURL,
            contentKey: contentKey,
            noncePrefix: noncePrefix
        )
        let original = E2eeAttachmentManifestAssetV1(
            assetId: UUID().uuidString,
            kind: .original,
            cipherSize: encrypted.ciphertextSize,
            cipherSha256: cipherHashOverride ?? encrypted.ciphertextSha256,
            frameSize: encrypted.frameSize,
            contentKey: contentKey.base64EncodedString(),
            noncePrefix: noncePrefix.base64EncodedString(),
            plaintextSize: encrypted.plaintextSize,
            plaintextSha256: encrypted.plaintextSha256,
            display: [
                "name": .string("verified.bin"),
                "mime_type": .string("application/octet-stream")
            ]
        )
        let manifest = E2eeAttachmentManifestV1(
            attachmentId: UUID().uuidString,
            assets: [original]
        )
        let cid = try ChannelId(cid: "team:project:original-download")
        let messageId = "message-\(UUID().uuidString)"
        let database = try makeDatabase()
        do {
            try database.writeAndWait { session in
                let channel = try session.saveChannel(
                    payload: try channelPayload(cid: cid.rawValue, messageId: messageId)
                )
                let message = try XCTUnwrap(channel.messages.first { $0.id == messageId })
                let decrypted = try session.saveMessageDecrypt(
                    payload: E2ePayload(
                        text: "",
                        attachments: [],
                        e2eeAttachments: [manifest],
                        stickerUrl: nil
                    ),
                    messageId: messageId,
                    ciphertextHash: Data([1, 2, 3])
                )
                message.decryptedMessage = decrypted
            }
        } catch {
            try? close(database)
            try? fileManager.removeItem(at: root)
            throw error
        }

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)
        let attachment = AnyMessageAttachment(
            id: AttachmentId(cid: cid, messageId: messageId, index: 0),
            type: renderable.type,
            payload: renderable.data,
            thumbnailData: nil,
            uploadingState: nil
        )
        return DownloadFixture(
            root: root,
            ciphertextDirectory: ciphertextDirectory,
            playbackDirectory: playbackDirectory,
            canonicalCiphertextURL: canonicalCiphertextURL,
            plaintext: plaintext,
            cid: cid,
            database: database,
            manifest: manifest,
            original: original,
            attachment: attachment,
            closeDatabase: { [weak database] in
                guard let database else { return }
                try? self.close(database)
            }
        )
    }

    private func makeDatabase() throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: .inMemory,
            shouldResetEphemeralValuesOnStart: false
        )
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [storeLoaded], timeout: 5), .completed)
        return database
    }

    private func close(_ database: DatabaseContainer) throws {
        for context in database.allContext {
            context.performAndWait { context.reset() }
        }
        for store in database.persistentStoreCoordinator.persistentStores {
            try database.persistentStoreCoordinator.remove(store)
        }
    }

    private func channelPayload(cid: String, messageId: String) throws -> ChannelPayload {
        let json = """
        {
          "channel": {
            "cid": "\(cid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-17T08:00:00.000Z",
            "created_at": "2026-08-17T07:00:00.000Z",
            "updated_at": "2026-08-17T08:00:00.000Z",
            "member_count": 2,
            "mls_enabled": true
          },
          "messages": [{
            "id": "\(messageId)",
            "type": "regular",
            "user": {"id": "sender", "project_id": "project"},
            "text": "",
            "mls_ciphertext": "AQID",
            "mls_epoch": 4,
            "created_at": "2026-08-17T08:00:00.000Z",
            "updated_at": "2026-08-17T08:00:00.000Z"
          }],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !predicate() {
            if DispatchTime.now().uptimeNanoseconds - startedAt > timeoutNanoseconds {
                throw TestError.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private enum TestError: Error {
        case timedOut
    }
}

private struct DownloadFixture {
    let root: URL
    let ciphertextDirectory: URL
    let playbackDirectory: URL
    let canonicalCiphertextURL: URL
    let plaintext: Data
    let cid: ChannelId
    let database: DatabaseContainer
    let manifest: E2eeAttachmentManifestV1
    let original: E2eeAttachmentManifestAssetV1
    let attachment: AnyMessageAttachment
    let closeDatabase: () -> Void

    func cleanup() {
        closeDatabase()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RecordedGrant: Equatable {
    let cid: ChannelId
    let attachmentId: String
    let assetId: String
}

private final class LockedGrantRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedGrant] = []

    var values: [RecordedGrant] {
        lock.withLock { storage }
    }

    @discardableResult
    func append(_ value: RecordedGrant) -> Int {
        lock.withLock {
            storage.append(value)
            return storage.count
        }
    }
}

private final class LockedDownloadPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [E2eeAttachmentOriginalDownloadProgress.Phase] = []

    var values: [E2eeAttachmentOriginalDownloadProgress.Phase] {
        lock.withLock { storage }
    }

    func append(_ phase: E2eeAttachmentOriginalDownloadProgress.Phase) {
        lock.withLock { storage.append(phase) }
    }
}

private final class CiphertextTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceURL: URL
    private let outputDirectory: URL
    private var statuses: [Int]
    private var calls = 0
    private var urls: [URL] = []

    init(sourceURL: URL, outputDirectory: URL, statuses: [Int]) {
        self.sourceURL = sourceURL
        self.outputDirectory = outputDirectory
        self.statuses = statuses
    }

    var callCount: Int { lock.withLock { calls } }
    var requestURLs: [URL] { lock.withLock { urls } }

    func download(
        request: URLRequest,
        expectedBytes: UInt64,
        progress: E2eeAttachmentOriginalDownloadCoordinator.ProgressHandler
    ) throws -> (URL, URLResponse) {
        let status: Int = lock.withLock {
            calls += 1
            if let url = request.url { urls.append(url) }
            return statuses.isEmpty ? 500 : statuses.removeFirst()
        }
        let destination = outputDirectory.appendingPathComponent("transport-\(UUID().uuidString).cipher")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        progress(.init(
            phase: .downloading,
            completedCiphertextBytes: expectedBytes,
            totalCiphertextBytes: expectedBytes
        ))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )
        )
        return (destination, response)
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
