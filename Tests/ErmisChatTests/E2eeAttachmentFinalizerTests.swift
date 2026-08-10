//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeAttachmentFinalizerTests: XCTestCase {
    private var directory: URL!
    private var stagingStore: E2eeAttachmentStagingStore!
    private var durableStore: E2eeDurableTransferStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2eeAttachmentFinalizerTests-\(UUID().uuidString)")
        stagingStore = E2eeAttachmentStagingStore(
            rootURL: directory,
            capacityProvider: FinalizerFixedCapacityProvider(capacity: UInt64.max)
        )
        try stagingStore.prepareEncryptedDirectories()
        durableStore = E2eeDurableTransferStore(rootURL: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        durableStore = nil
        stagingStore = nil
        directory = nil
    }

    func testRetryReusesExactDurableCompletionLeaseAndRequest() async throws {
        let client = RecordingAttachmentCompletionClient(
            outcomes: [
                .failure(E2eeAttachmentRemoteError(
                    category: .networkUnavailable,
                    isRetryable: true
                )),
                .success(())
            ]
        )
        let attempt = makeSinglePutAttempt()
        try durableStore.insert(attempt)
        let finalizer = E2eeAttachmentFinalizer(
            store: durableStore,
            stagingStore: stagingStore,
            client: client
        )

        do {
            _ = try await finalizer.finalize(attemptId: attempt.attemptId)
            XCTFail("Expected the first completion result to be retryable")
        } catch is E2eeAttachmentRemoteError {
            // Expected: the exact intent remains durable for retry.
        }
        let failed = try durableStore.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(failed.phase, .failedRetryable)
        XCTAssertEqual(failed.failureReason, .networkUnavailable)
        let firstIntent = try XCTUnwrap(failed.completionIntents?.first)
        XCTAssertFalse(firstIntent.isServiceCompleted)

        let completed = try await finalizer.finalize(attemptId: attempt.attemptId)
        let requests = client.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(
            requests[0].request.completionLeaseId,
            firstIntent.request.completionLeaseId
        )
        XCTAssertEqual(completed.phase, .finalizing)
        XCTAssertEqual(completed.completionIntents?.first?.isServiceCompleted, true)
    }

    func testMultipartCompletionUsesExactOpaqueEtagsThenCleansPartDirectory() async throws {
        let client = RecordingAttachmentCompletionClient(outcomes: [.success(())])
        let attachmentId = UUID().uuidString
        let assetId = UUID().uuidString
        let attemptId = UUID().uuidString
        let partDirectory = try stagingStore.multipartAssetDirectory(
            attemptId: attemptId,
            assetId: assetId
        )
        let stalePart = partDirectory.appendingPathComponent("part-001.cipher")
        try Data("already-uploaded".utf8).write(to: stalePart)

        var asset = PendingE2eeAsset(
            attachmentId: attachmentId,
            assetId: assetId,
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: nil,
            ciphertextSize: 20,
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: nil,
            uploadMode: .multipart,
            uploadExpiresAt: Date().addingTimeInterval(600),
            taskIdentifier: nil,
            taskToken: nil,
            parts: [
                .init(
                    number: 1,
                    offset: 0,
                    size: 10,
                    putURL: try XCTUnwrap(URL(string: "https://upload.example.test/part-1")),
                    eTag: "\"opaque-etag-1\"",
                    taskIdentifier: nil,
                    taskToken: nil,
                    localFileURL: nil
                ),
                .init(
                    number: 2,
                    offset: 10,
                    size: 10,
                    putURL: try XCTUnwrap(URL(string: "https://upload.example.test/part-2")),
                    eTag: "\"opaque-etag-2\"",
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
            cid: "team:project:channel",
            phase: .finalizing,
            totalBytes: 20
        )
        attempt.assets = [asset]
        try durableStore.insert(attempt)

        let finalizer = E2eeAttachmentFinalizer(
            store: durableStore,
            stagingStore: stagingStore,
            client: client
        )
        let completed = try await finalizer.finalize(attemptId: attemptId)

        let request = try XCTUnwrap(client.recordedRequests.first?.request)
        let completedParts = try XCTUnwrap(request.assets?.first?.multipart?.parts)
        XCTAssertEqual(completedParts.map(\.partNumber), [1, 2])
        XCTAssertEqual(completedParts.map(\.eTag), ["\"opaque-etag-1\"", "\"opaque-etag-2\""])
        XCTAssertEqual(completed.completionIntents?.first?.isServiceCompleted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partDirectory.path))
    }

    func testIncompleteTransportFailsClosedWithoutCallingService() async throws {
        let client = RecordingAttachmentCompletionClient(outcomes: [])
        var attempt = makeSinglePutAttempt()
        attempt.assets[0].isUploaded = false
        try durableStore.insert(attempt)
        let finalizer = E2eeAttachmentFinalizer(
            store: durableStore,
            stagingStore: stagingStore,
            client: client
        )

        do {
            _ = try await finalizer.finalize(attemptId: attempt.attemptId)
            XCTFail("Expected incomplete transport to fail closed")
        } catch let error as E2eeAttachmentFinalizerError {
            XCTAssertEqual(error, .transportIncomplete)
        }
        let failed = try durableStore.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(failed.phase, .failedTerminal)
        XCTAssertEqual(failed.failureReason, .invalidServerResponse)
        XCTAssertTrue(client.recordedRequests.isEmpty)
    }

    func testCompletedAssetsPersistManifestBeforeTransitioningToSending() async throws {
        let suiteName = "E2eeAttachmentFinalizerBinding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let wrappingKeyStore = E2eeAttachmentWrappingKeyStore(
            keychain: FinalizerKeychainStore(),
            defaults: defaults,
            access: .mainApp
        )
        let contentKey = Data((0..<32).map(UInt8.init))
        let noncePrefix = Data((32..<40).map(UInt8.init))
        let attempt = try makeBindingReadyAttempt(
            wrappingKeyStore: wrappingKeyStore,
            contentKey: contentKey,
            noncePrefix: noncePrefix
        )
        try durableStore.insert(attempt)
        let client = RecordingAttachmentCompletionClient(outcomes: [.success(())])
        let messageBinding = RecordingAttachmentMessageBinding()
        let finalizer = E2eeAttachmentFinalizer(
            store: durableStore,
            stagingStore: stagingStore,
            client: client,
            manifestBuilder: E2eeAttachmentManifestBuilder(
                wrappingKeyStore: wrappingKeyStore
            ),
            messageBinding: messageBinding
        )

        let completed = try await finalizer.finalize(attemptId: attempt.attemptId)

        XCTAssertEqual(completed.phase, .confirmed)
        XCTAssertEqual(messageBinding.persistedMessageId, attempt.messageId)
        XCTAssertEqual(messageBinding.sentMessageId, attempt.messageId)
        XCTAssertTrue(messageBinding.sendObservedDurableManifest)
        let manifestAsset = try XCTUnwrap(messageBinding.manifests?.first?.assets.first)
        XCTAssertEqual(manifestAsset.contentKey, contentKey.base64EncodedString())
        XCTAssertEqual(manifestAsset.noncePrefix, noncePrefix.base64EncodedString())
    }

    func testMessageSendFailureDoesNotLeaveAttemptSendingForever() async throws {
        let suiteName = "E2eeAttachmentFinalizerSendFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let wrappingKeyStore = E2eeAttachmentWrappingKeyStore(
            keychain: FinalizerKeychainStore(),
            defaults: defaults,
            access: .mainApp
        )
        let attempt = try makeBindingReadyAttempt(
            wrappingKeyStore: wrappingKeyStore,
            contentKey: Data((0..<32).map(UInt8.init)),
            noncePrefix: Data((32..<40).map(UInt8.init))
        )
        try durableStore.insert(attempt)
        let sendError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        )
        let messageBinding = RecordingAttachmentMessageBinding(sendError: sendError)
        let finalizer = E2eeAttachmentFinalizer(
            store: durableStore,
            stagingStore: stagingStore,
            client: RecordingAttachmentCompletionClient(outcomes: [.success(())]),
            manifestBuilder: E2eeAttachmentManifestBuilder(
                wrappingKeyStore: wrappingKeyStore
            ),
            messageBinding: messageBinding
        )

        do {
            _ = try await finalizer.finalize(attemptId: attempt.attemptId)
            XCTFail("Expected message binding failure")
        } catch {
            XCTAssertEqual((error as NSError).code, NSURLErrorNotConnectedToInternet)
        }

        let failed = try durableStore.attempt(attemptId: attempt.attemptId)
        XCTAssertEqual(failed.phase, .failedRetryable)
        XCTAssertEqual(failed.failureReason, .unknown)
        XCTAssertEqual(failed.completionIntents?.first?.isServiceCompleted, true)
        XCTAssertEqual(messageBinding.persistedMessageId, attempt.messageId)
        XCTAssertEqual(messageBinding.sentMessageId, attempt.messageId)
    }

    func testSendingAttemptRecoveryCanClosePreviouslyPersistedMessage() async throws {
        var attempt = makeSinglePutAttempt()
        attempt.phase = .sending
        try durableStore.insert(attempt)
        let messageBinding = RecordingAttachmentMessageBinding()
        let finalizer = E2eeAttachmentFinalizer(
            store: durableStore,
            stagingStore: stagingStore,
            client: RecordingAttachmentCompletionClient(outcomes: []),
            messageBinding: messageBinding
        )

        let recovered = try await finalizer.finalize(attemptId: attempt.attemptId)

        XCTAssertEqual(recovered.phase, .confirmed)
        XCTAssertEqual(messageBinding.sentMessageId, attempt.messageId)
    }

    private func makeBindingReadyAttempt(
        wrappingKeyStore: E2eeAttachmentWrappingKeyStore,
        contentKey: Data,
        noncePrefix: Data
    ) throws -> PendingE2eeTransferAttempt {
        let sealed = try wrappingKeyStore.seal(E2eeAttachmentSecretMaterial(
            contentKey: contentKey,
            noncePrefix: noncePrefix
        ))
        var asset = PendingE2eeAsset(
            attachmentId: UUID().uuidString,
            assetId: UUID().uuidString,
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: nil,
            ciphertextSize: UInt64(E2eeAttachmentFrameCryptoV1.emptyCiphertextSize),
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: sealed,
            frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
            plaintextSize: 0,
            plaintextSha256: String(repeating: "b", count: 64),
            uploadMode: .singlePut,
            uploadExpiresAt: Date().addingTimeInterval(600),
            taskIdentifier: nil,
            taskToken: nil,
            parts: []
        )
        asset.isUploaded = true
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "team:project:channel",
            phase: .finalizing,
            totalBytes: Int64(E2eeAttachmentFrameCryptoV1.emptyCiphertextSize)
        )
        attempt.assets = [asset]
        return attempt
    }

    private func makeSinglePutAttempt() -> PendingE2eeTransferAttempt {
        var asset = PendingE2eeAsset(
            attachmentId: UUID().uuidString,
            assetId: UUID().uuidString,
            kind: .original,
            sourceURL: nil,
            canonicalCiphertextURL: nil,
            ciphertextSize: 24,
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
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "team:project:channel",
            phase: .finalizing,
            totalBytes: 24
        )
        attempt.assets = [asset]
        return attempt
    }
}

private final class RecordingAttachmentCompletionClient: E2eeAttachmentCompletionClient {
    struct RecordedRequest: Equatable {
        let cid: String
        let attachmentId: String
        let request: CompleteE2eeAttachmentRequest
    }

    private let lock = NSLock()
    private var outcomes: [Result<Void, Error>]
    private var requests: [RecordedRequest] = []

    init(outcomes: [Result<Void, Error>]) {
        self.outcomes = outcomes
    }

    var recordedRequests: [RecordedRequest] {
        lock.withLock { requests }
    }

    func completePendingE2eeAttachment(
        cid: ChannelId,
        attachmentId: String,
        request: CompleteE2eeAttachmentRequest
    ) async throws {
        let outcome = lock.withLock { () -> Result<Void, Error> in
            requests.append(.init(
                cid: cid.rawValue,
                attachmentId: attachmentId,
                request: request
            ))
            return outcomes.isEmpty ? .success(()) : outcomes.removeFirst()
        }
        try outcome.get()
    }
}

private final class RecordingAttachmentMessageBinding: E2eeAttachmentMessageBinding {
    private let lock = NSLock()
    private(set) var persistedMessageId: String?
    private(set) var manifests: [E2eeAttachmentManifestV1]?
    private(set) var sentMessageId: String?
    private(set) var sendObservedDurableManifest = false
    private let sendError: Error?

    init(sendError: Error? = nil) {
        self.sendError = sendError
    }

    func persistCompletedE2eeAttachmentManifests(
        messageId: String,
        manifests: [E2eeAttachmentManifestV1]
    ) async throws {
        lock.withLock {
            persistedMessageId = messageId
            self.manifests = manifests
        }
    }

    func sendPreparedE2eeAttachmentMessage(messageId: String) async throws {
        lock.withLock {
            sentMessageId = messageId
            sendObservedDurableManifest = persistedMessageId == messageId && manifests?.isEmpty == false
        }
        if let sendError {
            throw sendError
        }
    }
}

private final class FinalizerKeychainStore: E2eeAttachmentKeychainStoring {
    private let lock = NSLock()
    private var stored: Data?

    func load() throws -> Data? { lock.withLock { stored } }

    func addAtomically(_ data: Data) throws -> E2eeAttachmentKeychainAddResult {
        lock.withLock {
            guard stored == nil else { return .duplicate }
            stored = data
            return .inserted
        }
    }
}

private struct FinalizerFixedCapacityProvider: E2eeAttachmentCapacityProviding {
    let capacity: UInt64

    func availableCapacity(at url: URL) throws -> UInt64 { capacity }
}
