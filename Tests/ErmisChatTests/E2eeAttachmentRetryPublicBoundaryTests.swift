//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeAttachmentRetryPublicBoundaryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeAttachmentRetryPublicBoundaryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testPublicRetryRoutesThroughDatabaseObserverToDurableFinalization() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://chat.example.test"))
        var config = ErmisClientConfig(
            apiKeyString: "retry-boundary-test",
            endpointEnviroment: EndpointEnviroment(baseURL: baseURL)
        )
        config.localStorageScope = .inMemory
        config.isClientInActiveMode = false
        config.urlSessionConfiguration = .ephemeral
        let client = ErmisClient(
            config: config,
            token: nil,
            notificationTokenProvider: nil
        )
        try waitForPersistentStore(in: client.databaseContainer)

        let cid = try ChannelId(cid: "team:project:retry-boundary")
        let messageId = "retry-message"
        let attachmentId = AttachmentId(cid: cid, messageId: messageId, index: 0)
        let sourceURL = directory.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: sourceURL)
        try client.databaseContainer.writeAndWait { session in
            _ = try session.saveChannel(payload: channelPayload())
            let payload = try AnyAttachmentPayload(
                localFileURL: sourceURL,
                attachmentType: .file
            )
            let attachment = try session.createNewAttachment(
                attachment: payload,
                id: attachmentId
            )
            attachment.localState = .uploadingFailed
            session.message(id: messageId)?.localMessageState = .sendingFailed
        }

        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.tests.\(UUID().uuidString)",
            endpoint: baseURL,
            applicationGroupIdentifier: nil
        )
        let scopedRoot = directory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(descriptor.storageNamespace, isDirectory: true)
        let stagingStore = E2eeAttachmentStagingStore(rootURL: scopedRoot)
        try stagingStore.prepareEncryptedDirectories()
        let canonicalURL = stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("completed.cipher")
        try Data((0..<10).map(UInt8.init)).write(to: canonicalURL)

        var asset = PendingE2eeAsset(
            attachmentId: attachmentId.rawValue,
            assetId: "asset-original",
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: canonicalURL,
            ciphertextSize: 10,
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: nil,
            uploadMode: .singlePut,
            uploadExpiresAt: Date().addingTimeInterval(600),
            taskIdentifier: nil,
            taskToken: nil,
            parts: []
        )
        asset.isUploaded = true
        var attempt = PendingE2eeTransferAttempt(
            accountId: "me",
            messageId: messageId,
            cid: cid.rawValue,
            phase: .failedRetryable,
            totalBytes: 10
        )
        attempt.failureReason = .unknown
        attempt.completedBytes = 10
        attempt.assets = [asset]

        let durableStore = E2eeDurableTransferStore(rootURL: scopedRoot)
        try durableStore.insert(attempt)
        let transferCoordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in .ephemeral }
        )
        let initializer = RetryBoundaryUnexpectedInitializer()
        let preparationCoordinator = E2eeAttachmentPreparationCoordinator(
            transferCoordinator: transferCoordinator,
            initializingClient: initializer
        )
        let uploader = AttachmentQueueUploader(
            database: client.databaseContainer,
            apiClient: client.apiClient,
            attachmentPostProcessor: nil,
            e2eePreparationCoordinator: preparationCoordinator,
            currentUserId: { "me" }
        )

        let retryCompleted = expectation(description: "public retry database mutation completed")
        client.messageController(cid: cid, messageId: messageId)
            .restartFailedAttachmentUploading(with: attachmentId) { error in
                XCTAssertNil(error)
                retryCompleted.fulfill()
            }
        wait(for: [retryCompleted], timeout: 2)

        let routed = expectation(description: "database observer routed durable retry")
        DispatchQueue.global().async {
            for _ in 0..<60 {
                let phase = try? durableStore.attempt(attemptId: attempt.attemptId).phase
                var attachmentState: LocalAttachmentState?
                client.databaseContainer.backgroundReadOnlyContext.performAndWait {
                    attachmentState = client.databaseContainer.backgroundReadOnlyContext
                        .attachment(id: attachmentId)?.localState
                }
                if phase == .finalizing,
                   case .uploading = attachmentState {
                    routed.fulfill()
                    return
                }
                usleep(50_000)
            }
        }
        wait(for: [routed], timeout: 3)

        let updated = try durableStore.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(updated.phase, .finalizing)
        XCTAssertNil(updated.failureReason)
        XCTAssertEqual(updated.completedBytes, 10)
        XCTAssertEqual(initializer.requestCount, 0)
        withExtendedLifetime(uploader) {}
    }

    private func waitForPersistentStore(in database: DatabaseContainer) throws {
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [storeLoaded], timeout: 5) == .completed else {
            throw XCTSkip("Timed out waiting for the in-memory persistent store")
        }
    }

    private func channelPayload() throws -> ChannelPayload {
        let json = """
        {
          "channel": {
            "cid": "team:project:retry-boundary",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-22T08:00:00.000Z",
            "created_at": "2026-08-22T08:00:00.000Z",
            "updated_at": "2026-08-22T08:00:00.000Z",
            "member_count": 1,
            "mls_enabled": true
          },
          "messages": [{
            "id": "retry-message",
            "type": "regular",
            "user": {"id": "me", "project_id": "project"},
            "text": "",
            "created_at": "2026-08-22T08:00:00.000Z",
            "updated_at": "2026-08-22T08:00:00.000Z"
          }],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }
}

private final class RetryBoundaryUnexpectedInitializer: E2eeAttachmentInitializing {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    func initializeE2eeAttachment(
        cid: ChannelId,
        request: InitE2eeAttachmentRequest
    ) async throws -> InitE2eeAttachmentResponse {
        lock.withLock { requests += 1 }
        throw E2eeAttachmentPreparationError.invalidInitResponse
    }
}
