//
// Copyright 2026 Ermis Inc.
//

import Foundation
import Security
@testable import ErmisChat
import XCTest

final class E2eeAttachmentSecureStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "E2eeAttachmentSecureStorageTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        suiteName = nil
        directory = nil
    }

    func testMainAppAtomicallyCreatesAndRoundTripsSealedSecret() throws {
        let keychain = FakeAttachmentKeychain()
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: keychain,
            defaults: defaults,
            access: .mainApp
        )
        let material = try E2eeAttachmentSecretMaterial(
            contentKey: Data(repeating: 7, count: 32),
            noncePrefix: Data(repeating: 8, count: 8)
        )

        let sealed = try store.seal(material)

        XCTAssertEqual(try store.unseal(sealed), material)
        XCTAssertEqual(sealed.wrappingKeyVersion, 1)
        XCTAssertTrue(defaults.bool(forKey: E2eeAttachmentWrappingKeyStore.initializedMarker))
        XCTAssertEqual(keychain.addCount, 1)
    }

    func testDuplicateAddLoadsAuthoritativeKeyInsteadOfOverwriting() throws {
        let keychain = FakeAttachmentKeychain()
        keychain.reportDuplicateOnFirstAdd = true
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: keychain,
            defaults: defaults,
            access: .mainApp
        )
        let material = try E2eeAttachmentSecretMaterial(
            contentKey: Data(repeating: 1, count: 32),
            noncePrefix: Data(repeating: 2, count: 8)
        )

        let sealed = try store.seal(material)

        XCTAssertEqual(try store.unseal(sealed), material)
        XCTAssertEqual(keychain.addCount, 1)
    }

    func testBeforeFirstUnlockDoesNotCreateOrRotateKey() throws {
        let keychain = FakeAttachmentKeychain()
        keychain.loadError = E2eeAttachmentKeychainStatusError(status: errSecInteractionNotAllowed)
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: keychain,
            defaults: defaults,
            access: .mainApp
        )

        XCTAssertThrowsError(try store.seal(makeMaterial())) { error in
            XCTAssertEqual(error as? E2eeAttachmentWrappingKeyError, .waitingForFirstUnlock)
        }
        XCTAssertEqual(keychain.addCount, 0)
    }

    func testTransientKeychainFailureDoesNotBecomeKeyLoss() throws {
        let keychain = FakeAttachmentKeychain()
        keychain.loadError = E2eeAttachmentKeychainStatusError(status: errSecNotAvailable)
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: keychain,
            defaults: defaults,
            access: .mainApp
        )

        XCTAssertThrowsError(try store.seal(makeMaterial())) { error in
            XCTAssertEqual(
                error as? E2eeAttachmentWrappingKeyError,
                .temporarilyUnavailable(errSecNotAvailable)
            )
        }
        XCTAssertEqual(keychain.addCount, 0)
    }

    func testMarkerProvenMissingKeyIsTerminalReinstallMismatch() throws {
        defaults.set(true, forKey: E2eeAttachmentWrappingKeyStore.initializedMarker)
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: FakeAttachmentKeychain(),
            defaults: defaults,
            access: .mainApp
        )

        XCTAssertThrowsError(try store.seal(makeMaterial())) { error in
            XCTAssertEqual(
                error as? E2eeAttachmentWrappingKeyError,
                .localKeyUnavailableAfterReinstall
            )
        }
    }

    func testExtensionCannotCreateWrappingKey() throws {
        let keychain = FakeAttachmentKeychain()
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: keychain,
            defaults: defaults,
            access: .readOnlyExtension
        )

        XCTAssertThrowsError(try store.seal(makeMaterial())) { error in
            XCTAssertEqual(
                error as? E2eeAttachmentWrappingKeyError,
                .mutationForbiddenOutsideMainApp
            )
        }
        XCTAssertEqual(keychain.addCount, 0)
    }

    func testWrappingKeyVersionMismatchFailsClosed() throws {
        let store = E2eeAttachmentWrappingKeyStore(
            keychain: FakeAttachmentKeychain(),
            defaults: defaults,
            access: .mainApp
        )
        let sealed = try store.seal(makeMaterial())
        let mismatched = E2eeSealedAttachmentSecret(
            wrappingKeyVersion: sealed.wrappingKeyVersion + 1,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )

        XCTAssertThrowsError(try store.unseal(mismatched)) { error in
            XCTAssertEqual(
                error as? E2eeAttachmentWrappingKeyError,
                .localKeyUnavailableAfterReinstall
            )
        }
    }

    func testDiskPreflightUsesBoundedMultipartWindowAndReserve() throws {
        let required = try E2eeAttachmentStagingStore.requiredCapacity(
            originalCipherSize: 10,
            previewCipherSize: 20,
            partCount: 256,
            concurrency: 3,
            partSize: 100
        )

        XCTAssertEqual(required, 10 + 20 + 400 + 100 * 1024 * 1024)
    }

    func testDiskPreflightRejectsInsufficientCapacityBeforeWork() throws {
        let store = E2eeAttachmentStagingStore(
            rootURL: directory,
            capacityProvider: FixedCapacityProvider(capacity: 1)
        )

        XCTAssertThrowsError(
            try store.preflight(
                originalCipherSize: 24,
                previewCipherSize: 0,
                partCount: 0,
                concurrency: 3,
                partSize: 0
            )
        ) { error in
            guard let stagingError = error as? E2eeAttachmentStagingError,
                  case .insufficientCapacity(let required, let available) = stagingError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(required, 24 + 100 * 1024 * 1024)
            XCTAssertEqual(available, 1)
        }
    }

    func testPartialFilePromotionIsAtomicAndDoesNotOverwriteDestination() throws {
        let store = E2eeAttachmentStagingStore(
            rootURL: directory,
            capacityProvider: FixedCapacityProvider(capacity: UInt64.max)
        )
        try store.prepareEncryptedDirectories()
        let destination = store.canonicalCiphertextDirectory.appendingPathComponent("asset.cipher")
        let partial = store.partialURL(for: destination)
        try Data("ciphertext".utf8).write(to: partial)

        try store.promotePartialFile(partial, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("ciphertext".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let secondPartial = store.partialURL(for: destination)
        try Data("replacement".utf8).write(to: secondPartial)
        XCTAssertThrowsError(try store.promotePartialFile(secondPartial, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("ciphertext".utf8))
    }

    func testNoSpaceClassificationPreservesStage() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))

        XCTAssertEqual(
            E2eeAttachmentStagingStore.classifyDiskError(error, stage: .partCreation)
                as? E2eeAttachmentStagingError,
            .noSpace(.partCreation)
        )
    }

    func testWrappedNoSpaceClassificationPreservesStage() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertEqual(
            E2eeAttachmentStagingStore.classifyDiskError(wrapped, stage: .download)
                as? E2eeAttachmentStagingError,
            .noSpace(.download)
        )
    }

    func testSourceStagingUsesAtomicDurableCopy() throws {
        let store = E2eeAttachmentStagingStore(
            rootURL: directory,
            capacityProvider: FixedCapacityProvider(capacity: UInt64.max)
        )
        let source = directory.appendingPathComponent("picker-source.jpg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("original image bytes".utf8).write(to: source)
        let destination = try store.sourceURL(
            attemptId: UUID().uuidString,
            attachmentIndex: 0,
            fileExtension: "jpg"
        )

        try store.stageSourceFile(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("original image bytes".utf8))
        XCTAssertTrue(destination.path.hasPrefix(store.sourceDirectory.path + "/"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: store.sourceDirectory.path)
                .contains(where: { $0.hasSuffix(".partial") })
        )
    }

    func testPreviewStagingUsesExplicitPartialPromotionWithoutFoundationOptionTrap() throws {
        let store = E2eeAttachmentStagingStore(
            rootURL: directory,
            capacityProvider: FixedCapacityProvider(capacity: UInt64.max)
        )
        let destination = try store.sourceURL(
            attemptId: UUID().uuidString,
            attachmentIndex: 1,
            fileExtension: "jpg"
        )
        let preview = Data("bounded preview bytes".utf8)

        try store.stagePreviewData(preview, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), preview)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: store.sourceDirectory.path)
                .contains(where: { $0.hasSuffix(".partial") })
        )
        XCTAssertThrowsError(try store.stagePreviewData(preview, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), preview)
    }

    func testPreparationPersistsCanonicalCiphertextBeforeSchedulingPut() throws {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.preparation-tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let coordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [PreparationHoldingURLProtocol.self]
                return configuration
            }
        )
        let initializer = PreparationAttachmentInitializer()
        let preparation = E2eeAttachmentPreparationCoordinator(
            transferCoordinator: coordinator,
            initializingClient: initializer,
            wrappingKeyStore: E2eeAttachmentWrappingKeyStore(
                keychain: FakeAttachmentKeychain(),
                defaults: defaults,
                access: .mainApp
            )
        )
        let source = directory.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((0..<255).map(UInt8.init)).write(to: source)
        let completed = expectation(description: "prepared and scheduled")
        var result: Result<String, Error>?

        preparation.prepareAndSchedule(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:preflight-tests:\(UUID().uuidString)",
            attachments: [
                E2eeAttachmentPreparationInput(
                    sourceURL: source,
                    title: "source.bin",
                    mimeType: "application/octet-stream",
                    display: ["name": .string("source.bin")],
                    generatesImagePreview: false
                )
            ]
        ) {
            result = $0
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
        let attemptId = try XCTUnwrap(try result?.get())
        let attempt = try coordinator.store.attempt(attemptId: attemptId)
        let asset = try XCTUnwrap(attempt.assets.first)
        XCTAssertEqual(initializer.requestCount, 1)
        XCTAssertTrue(
            [.uploading, .reconciling].contains(attempt.phase),
            "An active URLSession task may already be in the coordinator's reconciliation pass"
        )
        XCTAssertNotNil(asset.sealedSecret)
        XCTAssertEqual(asset.uploadMode, .singlePut)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(asset.canonicalCiphertextURL).path
            )
        )
        XCTAssertGreaterThan(asset.ciphertextSize ?? 0, 255)

        let canceled = expectation(description: "cancel prepared upload")
        coordinator.cancelTasks(accountId: "account-a") { _ in canceled.fulfill() }
        wait(for: [canceled], timeout: 2)
    }

    func testExpiredUploadRetryReinitializesWithFreshIdempotencyAndSameCiphertext() throws {
        let descriptor = E2eeBackgroundSessionDescriptor(
            bundleIdentifier: "network.ermis.expired-retry-tests.\(UUID().uuidString)",
            endpoint: try XCTUnwrap(URL(string: "https://chat.example.test")),
            applicationGroupIdentifier: nil
        )
        let coordinator = E2eeBackgroundTransferCoordinator(
            descriptor: descriptor,
            rootURL: directory,
            applicationGroupIdentifier: nil,
            sessionConfigurationBuilder: { _, _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [PreparationHoldingURLProtocol.self]
                return configuration
            }
        )
        let initializer = PreparationAttachmentInitializer(failureRequestNumbers: [2])
        let preparation = E2eeAttachmentPreparationCoordinator(
            transferCoordinator: coordinator,
            initializingClient: initializer,
            wrappingKeyStore: E2eeAttachmentWrappingKeyStore(
                keychain: FakeAttachmentKeychain(),
                defaults: defaults,
                access: .mainApp
            )
        )
        try coordinator.stagingStore.prepareEncryptedDirectories()
        let canonicalURL = coordinator.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        let canonicalBytes = Data((0..<48).map(UInt8.init))
        try canonicalBytes.write(to: canonicalURL)
        let secondCanonicalURL = coordinator.stagingStore.canonicalCiphertextDirectory
            .appendingPathComponent("\(UUID().uuidString).cipher")
        let secondCanonicalBytes = Data((48..<96).map(UInt8.init))
        try secondCanonicalBytes.write(to: secondCanonicalURL)

        let oldAttachmentId = UUID().uuidString
        let oldAssetId = UUID().uuidString
        let oldIdempotencyKey = UUID().uuidString
        var asset = PendingE2eeAsset(
            attachmentId: oldAttachmentId,
            assetId: oldAssetId,
            kind: .original,
            idempotencyKey: oldIdempotencyKey,
            sourceURL: nil,
            canonicalCiphertextURL: canonicalURL,
            ciphertextSize: UInt64(canonicalBytes.count),
            ciphertextSha256: String(repeating: "a", count: 64),
            sealedSecret: nil,
            uploadMode: .singlePut,
            uploadExpiresAt: Date().addingTimeInterval(-60),
            putURL: try XCTUnwrap(URL(string: "https://upload.example.test/expired")),
            taskIdentifier: nil,
            taskToken: nil,
            isUploaded: false,
            parts: []
        )
        asset.completedBytes = 24
        let secondOldAttachmentId = UUID().uuidString
        let secondOldAssetId = UUID().uuidString
        let secondOldIdempotencyKey = UUID().uuidString
        var secondAsset = asset
        secondAsset.attachmentId = secondOldAttachmentId
        secondAsset.assetId = secondOldAssetId
        secondAsset.idempotencyKey = secondOldIdempotencyKey
        secondAsset.canonicalCiphertextURL = secondCanonicalURL
        var attempt = PendingE2eeTransferAttempt(
            accountId: "account-a",
            messageId: UUID().uuidString,
            cid: "messaging:expired-retry-tests:\(UUID().uuidString)",
            phase: .failedRetryable,
            totalBytes: Int64(canonicalBytes.count + secondCanonicalBytes.count)
        )
        attempt.completedBytes = 24
        attempt.failureReason = .uploadExpired
        attempt.assets = [asset, secondAsset]
        try coordinator.store.insert(attempt)

        let firstInitFailed = expectation(description: "first fresh init failed retryably")
        let reinitialized = expectation(description: "expired upload reinitialized and scheduled")
        let observationLock = NSLock()
        var observedRetryableInitFailure = false
        var observedActiveSnapshot = false
        let observerId = preparation.addTransferObserver { snapshot in
            guard snapshot.attemptId == attempt.attemptId else { return }
            let fulfillments: (failed: Bool, active: Bool) = observationLock.withLock {
                var failed = false
                var active = false
                if !observedRetryableInitFailure,
                   snapshot.phase == .failedRetryable,
                   snapshot.failureReason == .networkUnavailable,
                   snapshot.assets.contains(where: { $0.uploadMode != nil }),
                   snapshot.assets.contains(where: { $0.uploadMode == nil }) {
                    observedRetryableInitFailure = true
                    failed = true
                }
                if !observedActiveSnapshot,
                   [.uploading, .reconciling].contains(snapshot.phase),
                   snapshot.assets.allSatisfy({ $0.taskToken != nil }) {
                    observedActiveSnapshot = true
                    active = true
                }
                return (failed, active)
            }
            if fulfillments.failed { firstInitFailed.fulfill() }
            if fulfillments.active { reinitialized.fulfill() }
        }
        preparation.retryAndResumeDurableTransfer(
            messageId: attempt.messageId,
            accountId: attempt.accountId
        )
        wait(for: [firstInitFailed], timeout: 4)

        let failedRequest = try XCTUnwrap(initializer.requestSnapshot.last)
        XCTAssertEqual(initializer.requestCount, 2)
        preparation.retryAndResumeDurableTransfer(
            messageId: attempt.messageId,
            accountId: attempt.accountId
        )
        preparation.retryAndResumeDurableTransfer(
            messageId: attempt.messageId,
            accountId: attempt.accountId
        )
        wait(for: [reinitialized], timeout: 4)
        preparation.removeTransferObserver(observerId)

        let updated = try coordinator.store.attempt(attemptId: attempt.attemptId)
        let updatedAsset = try XCTUnwrap(updated.assets.first)
        let updatedSecondAsset = try XCTUnwrap(updated.assets.last)
        let request = try XCTUnwrap(initializer.requestSnapshot.last)
        XCTAssertEqual(initializer.requestCount, 3)
        XCTAssertNotEqual(updatedAsset.idempotencyKey, oldIdempotencyKey)
        XCTAssertNotEqual(request.idempotencyKey, secondOldIdempotencyKey)
        XCTAssertEqual(request.idempotencyKey, failedRequest.idempotencyKey)
        XCTAssertEqual(updatedSecondAsset.idempotencyKey, request.idempotencyKey)
        XCTAssertNotEqual(updatedAsset.attachmentId, oldAttachmentId)
        XCTAssertNotEqual(updatedAsset.assetId, oldAssetId)
        XCTAssertNotEqual(updatedSecondAsset.attachmentId, secondOldAttachmentId)
        XCTAssertNotEqual(updatedSecondAsset.assetId, secondOldAssetId)
        XCTAssertEqual(updatedAsset.canonicalCiphertextURL, canonicalURL)
        XCTAssertEqual(updatedSecondAsset.canonicalCiphertextURL, secondCanonicalURL)
        XCTAssertNotNil(updatedAsset.taskToken)
        XCTAssertNotNil(updatedSecondAsset.taskToken)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalBytes)
        XCTAssertEqual(try Data(contentsOf: secondCanonicalURL), secondCanonicalBytes)
        XCTAssertEqual(updated.completedBytes, 0)
        XCTAssertNil(updated.failureReason)

        let canceled = expectation(description: "cancel fresh upload")
        coordinator.cancelTasks(accountId: attempt.accountId) { _ in canceled.fulfill() }
        wait(for: [canceled], timeout: 2)
    }

    func testPreparationEstimatesCiphertextAndPreviewBeforeStaging() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("early-preflight.jpg")
        try Data(repeating: 0x2a, count: 512).write(to: source)

        let capacity = try E2eeAttachmentPreparationCoordinator.estimatedCiphertextCapacity(
            for: [
                E2eeAttachmentPreparationInput(
                    sourceURL: source,
                    title: "early-preflight.jpg",
                    mimeType: "image/jpeg",
                    display: [:],
                    generatesImagePreview: true
                )
            ]
        )

        XCTAssertEqual(
            capacity.original,
            try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(plaintextSize: 512)
        )
        XCTAssertEqual(capacity.preview, E2eeAttachmentFrameCryptoV1.previewCiphertextLimit)
    }

    func testPreparationEarlyEstimateRejectsMissingSource() {
        let missing = directory.appendingPathComponent("missing.mov")

        XCTAssertThrowsError(
            try E2eeAttachmentPreparationCoordinator.estimatedCiphertextCapacity(
                for: [
                    E2eeAttachmentPreparationInput(
                        sourceURL: missing,
                        title: "missing.mov",
                        mimeType: "video/quicktime",
                        display: [:],
                        generatesImagePreview: false,
                        generatesVideoPreview: true
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? E2eeAttachmentPreparationError, .sourceUnavailable)
        }
    }

    private func makeMaterial() throws -> E2eeAttachmentSecretMaterial {
        try E2eeAttachmentSecretMaterial(
            contentKey: Data(repeating: 1, count: 32),
            noncePrefix: Data(repeating: 2, count: 8)
        )
    }
}

private final class PreparationAttachmentInitializer: E2eeAttachmentInitializing {
    private let lock = NSLock()
    private var requests: [InitE2eeAttachmentRequest] = []
    private var failureRequestNumbers: Set<Int>

    init(failureRequestNumbers: Set<Int> = []) {
        self.failureRequestNumbers = failureRequestNumbers
    }

    var requestCount: Int { lock.withLock { requests.count } }
    var requestSnapshot: [InitE2eeAttachmentRequest] { lock.withLock { requests } }

    func initializeE2eeAttachment(
        cid: ChannelId,
        request: InitE2eeAttachmentRequest
    ) async throws -> InitE2eeAttachmentResponse {
        let shouldFail = lock.withLock {
            requests.append(request)
            return failureRequestNumbers.remove(requests.count) != nil
        }
        if shouldFail {
            throw E2eeAttachmentRemoteError(category: .networkUnavailable, isRetryable: true)
        }
        let requested = try XCTUnwrap(request.assets.first)
        let expiry = try XCTUnwrap(
            DateFormatter.Ermis.rfc3339DateString(from: Date().addingTimeInterval(600))
        )
        return InitE2eeAttachmentResponse(
            attachmentId: UUID().uuidString,
            status: "initiated",
            uploadExpiresAt: expiry,
            assets: [
                InitE2eeAttachmentAssetResponse(
                    assetId: UUID().uuidString,
                    kind: requested.kind,
                    uploadMode: .singlePut,
                    putURL: try XCTUnwrap(URL(string: "https://upload.example.test/object")),
                    multipart: nil,
                    objectKey: "opaque-object-key",
                    cipherSizeEstimate: requested.cipherSizeEstimate
                )
            ]
        )
    }
}

private final class PreparationHoldingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class FakeAttachmentKeychain: E2eeAttachmentKeychainStoring {
    var data: Data?
    var loadError: Error?
    var reportDuplicateOnFirstAdd = false
    private(set) var addCount = 0

    func load() throws -> Data? {
        if let loadError { throw loadError }
        return data
    }

    func addAtomically(_ data: Data) throws -> E2eeAttachmentKeychainAddResult {
        addCount += 1
        if reportDuplicateOnFirstAdd {
            reportDuplicateOnFirstAdd = false
            self.data = data
            return .duplicate
        }
        if self.data != nil { return .duplicate }
        self.data = data
        return .inserted
    }
}

private struct FixedCapacityProvider: E2eeAttachmentCapacityProviding {
    let capacity: UInt64

    func availableCapacity(at url: URL) throws -> UInt64 {
        capacity
    }
}
