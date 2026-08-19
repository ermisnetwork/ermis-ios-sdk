//
// Copyright 2026 Ermis Inc.
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

protocol E2eeAttachmentInitializing: AnyObject {
    func initializeE2eeAttachment(
        cid: ChannelId,
        request: InitE2eeAttachmentRequest
    ) async throws -> InitE2eeAttachmentResponse
}

extension APIClient: E2eeAttachmentInitializing {
    func initializeE2eeAttachment(
        cid: ChannelId,
        request: InitE2eeAttachmentRequest
    ) async throws -> InitE2eeAttachmentResponse {
        try await initE2eeAttachment(cid: cid, request: request)
    }
}

struct E2eeAttachmentPreparationInput {
    let sourceURL: URL
    let title: String?
    let mimeType: String?
    let display: [String: RawJSON]
    let generatesImagePreview: Bool
    let generatesVideoPreview: Bool
    let videoDuration: TimeInterval?

    init(
        sourceURL: URL,
        title: String?,
        mimeType: String?,
        display: [String: RawJSON],
        generatesImagePreview: Bool,
        generatesVideoPreview: Bool = false,
        videoDuration: TimeInterval? = nil
    ) {
        self.sourceURL = sourceURL
        self.title = title
        self.mimeType = mimeType
        self.display = display
        self.generatesImagePreview = generatesImagePreview
        self.generatesVideoPreview = generatesVideoPreview
        self.videoDuration = videoDuration
    }
}

enum E2eeAttachmentPreparationError: Error, Equatable {
    case invalidAttachmentCount
    case invalidChannelId
    case sourceUnavailable
    case attachmentTooLarge
    case invalidInitResponse
    case previewTooLarge
}

/// Bridges composer-owned local files into the durable E2EE transfer state machine. Source copy,
/// framing, and hashing run away from the main thread. Bellboy init happens only after the exact
/// canonical ciphertext and its sealed key material are durable.
final class E2eeAttachmentPreparationCoordinator {
    private struct PreparedLogicalAttachment {
        let placeholderAttachmentId: String
        let idempotencyKey: String
    }

    private let transferCoordinator: E2eeBackgroundTransferCoordinator
    private weak var initializingClient: E2eeAttachmentInitializing?
    private let wrappingKeyStore: E2eeAttachmentWrappingKeyStore
    private let workQueue = DispatchQueue(
        label: "network.ermis.e2ee.attachment-preparation",
        qos: .utility
    )

    init(
        transferCoordinator: E2eeBackgroundTransferCoordinator,
        initializingClient: E2eeAttachmentInitializing,
        wrappingKeyStore: E2eeAttachmentWrappingKeyStore = E2eeAttachmentWrappingKeyStore(access: .mainApp)
    ) {
        self.transferCoordinator = transferCoordinator
        self.initializingClient = initializingClient
        self.wrappingKeyStore = wrappingKeyStore
    }

    @discardableResult
    func addTransferObserver(
        _ observer: @escaping (PendingE2eeTransferAttempt) -> Void
    ) -> UUID {
        transferCoordinator.addTransferObserver(observer)
    }

    func removeTransferObserver(_ id: UUID) {
        transferCoordinator.removeTransferObserver(id)
    }

    func hasDurableAttempt(messageId: String, accountId: String) -> Bool {
        transferCoordinator.hasDurableAttempt(messageId: messageId, accountId: accountId)
    }

    func retryAndResumeDurableTransfer(messageId: String, accountId: String) {
        transferCoordinator.retryAndResumeDurableTransfer(
            messageId: messageId,
            accountId: accountId
        )
    }

    func prepareAndSchedule(
        accountId: String,
        messageId: String,
        cid: String,
        attachments: [E2eeAttachmentPreparationInput],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let context = try self.prepareLocalAttempt(
                    accountId: accountId,
                    messageId: messageId,
                    cid: cid,
                    attachments: attachments
                )
                Task {
                    do {
                        try await self.initializeAndSchedule(
                            attemptId: context.attemptId,
                            logicalAttachments: context.logicalAttachments
                        )
                        completion(.success(context.attemptId))
                    } catch {
                        self.markFailedIfDurable(attemptId: context.attemptId, error: error)
                        completion(.failure(error))
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func prepareLocalAttempt(
        accountId: String,
        messageId: String,
        cid: String,
        attachments: [E2eeAttachmentPreparationInput]
    ) throws -> (attemptId: String, logicalAttachments: [PreparedLogicalAttachment]) {
        guard (1...10).contains(attachments.count) else {
            throw E2eeAttachmentPreparationError.invalidAttachmentCount
        }
        guard (try? ChannelId(cid: cid)) != nil else {
            throw E2eeAttachmentPreparationError.invalidChannelId
        }

        let attemptId = UUID().uuidString
        let staging = transferCoordinator.stagingStore
        let estimatedCapacity = try Self.estimatedCiphertextCapacity(for: attachments)
        // Fail before copying Photos/files into SDK-owned storage or writing any ciphertext.
        // The exact-size preflight below remains the authoritative boundary before Bellboy init.
        try staging.preflight(
            originalCipherSize: estimatedCapacity.original,
            previewCipherSize: estimatedCapacity.preview,
            partCount: 0,
            concurrency: 0,
            partSize: 0
        )
        try staging.prepareEncryptedDirectories()
        var pendingAssets: [PendingE2eeAsset] = []
        var logicalAttachments: [PreparedLogicalAttachment] = []
        var stagedSources: [URL] = []
        var stagedCiphertexts: [URL] = []
        var totalBytes: UInt64 = 0
        var inserted = false

        defer {
            if !inserted {
                stagedSources.forEach { try? staging.removeSource($0) }
                stagedCiphertexts.forEach { try? staging.removeCanonicalCiphertext($0) }
            }
        }

        for (attachmentIndex, input) in attachments.enumerated() {
            guard FileManager.default.fileExists(atPath: input.sourceURL.path) else {
                throw E2eeAttachmentPreparationError.sourceUnavailable
            }
            let sourceURL = try staging.sourceURL(
                attemptId: attemptId,
                attachmentIndex: attachmentIndex * 2,
                fileExtension: input.sourceURL.pathExtension
            )
            try staging.stageSourceFile(from: input.sourceURL, to: sourceURL)
            stagedSources.append(sourceURL)

            let originalDisplay = Self.normalizedDisplay(
                input.display,
                for: sourceURL
            )

            let placeholderAttachmentId = UUID().uuidString
            let idempotencyKey = UUID().uuidString
            let original = try encryptAsset(
                sourceURL: sourceURL,
                attemptId: attemptId,
                assetIndex: pendingAssets.count,
                attachmentId: placeholderAttachmentId,
                idempotencyKey: idempotencyKey,
                kind: .original,
                display: originalDisplay
            )
            pendingAssets.append(original)
            if let url = original.canonicalCiphertextURL { stagedCiphertexts.append(url) }
            totalBytes = try Self.add(totalBytes, original.ciphertextSize ?? 0)

            if (input.generatesImagePreview || input.generatesVideoPreview),
               let previewData = Self.makePreview(
                    at: sourceURL,
                    isVideo: input.generatesVideoPreview,
                    duration: input.videoDuration
               ),
               !previewData.isEmpty {
                let previewPlainURL = try staging.sourceURL(
                    attemptId: attemptId,
                    attachmentIndex: attachmentIndex * 2 + 1,
                    fileExtension: "jpg"
                )
                do {
                    try staging.stagePreviewData(previewData, to: previewPlainURL)
                    let previewDisplay: [String: RawJSON] = [
                        "name": .string((input.title ?? "preview") + ".preview.jpg"),
                        "mime_type": .string("image/jpeg"),
                        "size": .number(Double(previewData.count)),
                        "preview_of": .string("original")
                    ]
                    let preview = try encryptAsset(
                        sourceURL: previewPlainURL,
                        attemptId: attemptId,
                        assetIndex: pendingAssets.count,
                        attachmentId: placeholderAttachmentId,
                        idempotencyKey: idempotencyKey,
                        kind: .preview,
                        display: previewDisplay
                    )
                    guard (preview.ciphertextSize ?? 0) <= E2eeAttachmentFrameCryptoV1.previewCiphertextLimit else {
                        throw E2eeAttachmentPreparationError.previewTooLarge
                    }
                    pendingAssets.append(preview)
                    if let url = preview.canonicalCiphertextURL { stagedCiphertexts.append(url) }
                    totalBytes = try Self.add(totalBytes, preview.ciphertextSize ?? 0)
                } catch E2eeAttachmentPreparationError.previewTooLarge {
                    // V1 explicitly permits original-only when preview preparation exceeds its cap.
                } catch {
                    // Preview is optional. Original transport remains valid and byte-identical.
                }
                try? staging.removeSource(previewPlainURL)
            }

            logicalAttachments.append(
                PreparedLogicalAttachment(
                    placeholderAttachmentId: placeholderAttachmentId,
                    idempotencyKey: idempotencyKey
                )
            )
        }

        try staging.preflight(
            originalCipherSize: totalBytes,
            previewCipherSize: 0,
            partCount: 0,
            concurrency: 0,
            partSize: 0
        )
        var attempt = PendingE2eeTransferAttempt(
            attemptId: attemptId,
            accountId: accountId,
            messageId: messageId,
            cid: cid,
            phase: .encrypting,
            totalBytes: Int64(clamping: totalBytes)
        )
        attempt.assets = pendingAssets
        try transferCoordinator.store.insert(attempt)
        transferCoordinator.notifyTransferStoreChanged()
        inserted = true
        return (attemptId, logicalAttachments)
    }

    static func estimatedCiphertextCapacity(
        for attachments: [E2eeAttachmentPreparationInput]
    ) throws -> (original: UInt64, preview: UInt64) {
        var originalTotal: UInt64 = 0
        var previewTotal: UInt64 = 0
        for input in attachments {
            guard FileManager.default.fileExists(atPath: input.sourceURL.path),
                  let values = try? input.sourceURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize,
                  fileSize >= 0 else {
                throw E2eeAttachmentPreparationError.sourceUnavailable
            }
            let estimated = try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(
                plaintextSize: UInt64(fileSize)
            )
            guard estimated <= E2eeAttachmentFrameCryptoV1.originalCiphertextLimit else {
                throw E2eeAttachmentPreparationError.attachmentTooLarge
            }
            originalTotal = try Self.add(originalTotal, estimated)
            if input.generatesImagePreview || input.generatesVideoPreview {
                // Preview generation is optional and occurs after this early gate. Reserve its
                // complete wire cap so preparation cannot cross the free-space boundary later.
                previewTotal = try Self.add(
                    previewTotal,
                    E2eeAttachmentFrameCryptoV1.previewCiphertextLimit
                )
            }
        }
        return (originalTotal, previewTotal)
    }

    /// Derives wire metadata from the exact staged plaintext bytes, not from the item-provider
    /// hint. In particular this prevents a JPEG materialized from a Photos HEIC resource from
    /// being advertised with a stale size or MIME type.
    static func normalizedDisplay(
        _ display: [String: RawJSON],
        for sourceURL: URL
    ) -> [String: RawJSON] {
        var result = display
        if let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize,
           size >= 0 {
            result["size"] = .number(Double(size))
        }

#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceType = CGImageSourceGetType(source),
           let mimeType = UTType(sourceType as String)?.preferredMIMEType {
            result["mime_type"] = .string(mimeType)
            if mimeType == "image/jpeg",
               let oldName = result["name"]?.stringValue {
                let oldExtension = URL(fileURLWithPath: oldName).pathExtension.lowercased()
                if oldExtension.isEmpty || oldExtension == "heic" || oldExtension == "heif" {
                    let base = URL(fileURLWithPath: oldName)
                        .deletingPathExtension()
                        .lastPathComponent
                    result["name"] = .string(base + ".jpg")
                }
            }
        }
#endif
        return result
    }

    private func encryptAsset(
        sourceURL: URL,
        attemptId: String,
        assetIndex: Int,
        attachmentId: String,
        idempotencyKey: String,
        kind: E2eeAttachmentAssetKind,
        display: [String: RawJSON]
    ) throws -> PendingE2eeAsset {
        let keyMaterial = try E2eeAttachmentFrameCryptoV1.makeKeyMaterial()
        let secret = try E2eeAttachmentSecretMaterial(
            contentKey: keyMaterial.contentKey,
            noncePrefix: keyMaterial.noncePrefix
        )
        let sealedSecret = try wrappingKeyStore.seal(secret)
        let outputURL = try transferCoordinator.stagingStore.canonicalCiphertextURL(
            attemptId: attemptId,
            assetIndex: assetIndex
        )
        let result: E2eeAttachmentFrameCryptoResult
        do {
            result = try E2eeAttachmentFrameCryptoV1.encryptFile(
                at: sourceURL,
                to: outputURL,
                contentKey: keyMaterial.contentKey,
                noncePrefix: keyMaterial.noncePrefix
            )
            try transferCoordinator.stagingStore.secureStagedFile(outputURL)
        } catch {
            throw E2eeAttachmentStagingStore.classifyDiskError(error, stage: .encryption)
        }
        let limit = kind == .preview
            ? E2eeAttachmentFrameCryptoV1.previewCiphertextLimit
            : E2eeAttachmentFrameCryptoV1.originalCiphertextLimit
        guard result.ciphertextSize <= limit else {
            try? transferCoordinator.stagingStore.removeCanonicalCiphertext(outputURL)
            throw E2eeAttachmentPreparationError.attachmentTooLarge
        }
        return PendingE2eeAsset(
            attachmentId: attachmentId,
            assetId: UUID().uuidString,
            kind: kind,
            idempotencyKey: idempotencyKey,
            sourceURL: kind == .original ? sourceURL : nil,
            canonicalCiphertextURL: outputURL,
            ciphertextSize: result.ciphertextSize,
            ciphertextSha256: result.ciphertextSha256,
            sealedSecret: sealedSecret,
            frameSize: result.frameSize,
            plaintextSize: result.plaintextSize,
            plaintextSha256: result.plaintextSha256,
            display: display,
            parts: []
        )
    }

    private func initializeAndSchedule(
        attemptId: String,
        logicalAttachments: [PreparedLogicalAttachment]
    ) async throws {
        guard let initializingClient else {
            throw E2eeAttachmentPreparationError.invalidInitResponse
        }
        let attempt = try transferCoordinator.store.attempt(attemptId: attemptId)
        let cid = try ChannelId(cid: attempt.cid)

        for logical in logicalAttachments {
            let assets = attempt.assets.filter {
                $0.attachmentId == logical.placeholderAttachmentId
            }
            let request = InitE2eeAttachmentRequest(
                idempotencyKey: logical.idempotencyKey,
                assets: assets.map {
                    InitE2eeAttachmentAssetRequest(
                        kind: $0.kind,
                        cipherSizeEstimate: $0.ciphertextSize ?? 0
                    )
                }
            )
            log.info(
                "[E2EE_ATTACHMENT] stage=init state=requesting asset_count=\(assets.count)",
                subsystems: .mls
            )
            let response = try await initializingClient.initializeE2eeAttachment(
                cid: cid,
                request: request
            )
            let modes = response.assets.map(\.effectiveUploadMode.rawValue).sorted().joined(separator: ",")
            log.info(
                "[E2EE_ATTACHMENT] stage=init state=accepted modes=\(modes)",
                subsystems: .mls
            )
            let expiry = try responseExpiry(response.uploadExpiresAt)
            _ = try transferCoordinator.store.update(attemptId: attemptId) { record in
                for responseAsset in response.assets {
                    guard let index = record.assets.firstIndex(where: {
                        $0.attachmentId == logical.placeholderAttachmentId
                            && $0.kind == responseAsset.kind
                    }) else {
                        throw E2eeAttachmentPreparationError.invalidInitResponse
                    }
                    record.assets[index].attachmentId = response.attachmentId
                    record.assets[index].assetId = responseAsset.assetId
                    record.assets[index].uploadMode = responseAsset.effectiveUploadMode
                    record.assets[index].uploadExpiresAt = expiry
                    record.assets[index].putURL = responseAsset.putURL
                    record.assets[index].objectKey = responseAsset.objectKey
                    record.assets[index].multipartUploadId = responseAsset.multipart?.multipartUploadId
                    record.assets[index].multipartPartSize = responseAsset.multipart?.partSize
                    record.assets[index].maxPartRetries = responseAsset.multipart?.maxPartRetries
                    record.assets[index].retryMaxElapsedSeconds = responseAsset.multipart?.retryMaxElapsedSeconds
                    record.assets[index].parts = try responseAsset.effectiveUploadMode == .multipart
                        ? responseAsset.makePendingMultipartParts()
                        : []
                }
            }
            transferCoordinator.notifyTransferStoreChanged()
        }

        let initializedAttempt = try transferCoordinator.store.attempt(attemptId: attemptId)
        for asset in initializedAttempt.assets {
            guard let canonicalURL = asset.canonicalCiphertextURL,
                  let uploadMode = asset.uploadMode else {
                throw E2eeAttachmentPreparationError.invalidInitResponse
            }
            switch uploadMode {
            case .singlePut:
                guard let putURL = asset.putURL else {
                    throw E2eeAttachmentPreparationError.invalidInitResponse
                }
                var request = URLRequest(url: putURL)
                request.httpMethod = "PUT"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                _ = try transferCoordinator.scheduleSinglePut(
                    attemptId: attemptId,
                    assetId: asset.assetId,
                    request: request,
                    fileURL: canonicalURL
                )
            case .multipart:
                _ = try transferCoordinator.materializeMultipartWindow(
                    attemptId: attemptId,
                    assetId: asset.assetId
                )
            }
        }
        transferCoordinator.resumeMultipartUploads { result in
            if case .failure(let error) = result {
                log.error(
                    "[E2EE_ATTACHMENT] stage=post_schedule_reconcile state=failed error=\(e2eeTransferDiagnostic(error))",
                    subsystems: .mls
                )
            }
        }
        log.info(
            "[E2EE_ATTACHMENT] stage=schedule state=accepted asset_count=\(initializedAttempt.assets.count)",
            subsystems: .mls
        )
    }

    private func responseExpiry(_ value: String) throws -> Date {
        guard let date = DateFormatter.Ermis.rfc3339Date(from: value) else {
            throw E2eeAttachmentPreparationError.invalidInitResponse
        }
        return date
    }

    private func markFailedIfDurable(attemptId: String, error: Error) {
        let reason: E2eeTransferFailureReason
        let retryable: Bool
        if let remote = error as? E2eeAttachmentRemoteError {
            reason = remote.publicFailureReason
            retryable = remote.isRetryable
        } else if case E2eeAttachmentStagingError.noSpace = error {
            reason = .insufficientDiskSpace
            retryable = true
        } else if error as? E2eeAttachmentPreparationError == .attachmentTooLarge {
            reason = .attachmentTooLarge
            retryable = false
        } else {
            reason = .sourceUnavailable
            retryable = true
        }
        _ = try? transferCoordinator.store.update(attemptId: attemptId) { record in
            record.phase = retryable ? .failedRetryable : .failedTerminal
            record.failureReason = reason
        }
        log.error(
            "[E2EE_ATTACHMENT] stage=prepare_or_schedule state=failed reason=\(reason.rawValue) retryable=\(retryable)",
            subsystems: .mls
        )
        transferCoordinator.notifyTransferStoreChanged()
        transferCoordinator.notifyTransferStoreChanged()
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw E2eeAttachmentFrameCryptoError.sizeOverflow }
        return sum
    }

    private static func makeImagePreview(at sourceURL: URL) -> Data? {
#if canImport(UIKit) && canImport(ImageIO)
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceShouldCacheImmediately: false
                    ] as CFDictionary
                  ) else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.72)
        }
#else
        return nil
#endif
    }

    private static func makePreview(
        at sourceURL: URL,
        isVideo: Bool,
        duration: TimeInterval?
    ) -> Data? {
        guard isVideo else { return makeImagePreview(at: sourceURL) }
#if canImport(AVFoundation) && canImport(UIKit)
        return autoreleasepool {
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            let seconds = min(1, max(0, (duration ?? 1) * 0.1))
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            let lock = NSLock()
            var result: Data?
            let semaphore = DispatchSemaphore(value: 0)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) {
                _, image, _, _, _ in
                if let image {
                    let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.72)
                    lock.withLock { result = data }
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else {
                generator.cancelAllCGImageGeneration()
                return nil
            }
            return lock.withLock { result }
        }
#else
        return nil
#endif
    }
}
