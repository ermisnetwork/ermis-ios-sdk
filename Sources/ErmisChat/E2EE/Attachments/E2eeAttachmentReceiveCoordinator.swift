//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation

enum E2eeAttachmentReceiveSource: String {
    case websocket
    case scopeSync = "scope_sync"
    case messageUpdate = "message_update"
    case replayRecovery = "replay_recovery"
    case cachedModel = "cached_model"
    case directDecrypt = "direct_decrypt"
}

private enum E2eeAttachmentReceiveError: Error {
    case missingPreview
    case invalidHTTPResponse
    case invalidHTTPStatus(Int)
    case cipherSizeMismatch
    case cipherHashMismatch
    case plaintextSizeMismatch
    case plaintextHashMismatch
    case invalidKeyMaterial
    case previewTooLarge
    case unsupportedMedia
}

/// A preview can be requested more than once while websocket, scope-sync and the channel query
/// converge on the same message. Keep every render target attached to the single network flight;
/// dropping a later target can leave its cell spinning until the channel is queried again.
struct E2eeAttachmentPreviewPersistenceTarget {
    let manifest: E2eeAttachmentManifestV1
    let previewAssetId: String
    let attachmentId: AttachmentId
}

final class E2eeAttachmentPreviewFlightRegistry {
    private let lock = NSLock()
    private var targetsByAssetId: [String: [AttachmentId: E2eeAttachmentPreviewPersistenceTarget]] = [:]

    /// Returns `true` only for the caller that must start the network request. Other callers join
    /// the existing request and are persisted when that request completes.
    func register(
        assetId: String,
        target: E2eeAttachmentPreviewPersistenceTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if targetsByAssetId[assetId] != nil {
            targetsByAssetId[assetId]?[target.attachmentId] = target
            return false
        }
        targetsByAssetId[assetId] = [target.attachmentId: target]
        return true
    }

    func finish(assetId: String) -> [E2eeAttachmentPreviewPersistenceTarget] {
        lock.lock()
        defer { lock.unlock() }
        guard let targets = targetsByAssetId.removeValue(forKey: assetId) else { return [] }
        return Array(targets.values)
    }
}

/// Hydrates only encrypted preview assets for confirmed incoming E2EE messages. Original media is
/// intentionally not auto-downloaded; full original download/playback remains an explicit user
/// action and range streaming stays behind its independent feature gate.
final class E2eeAttachmentReceiveCoordinator {
    private let apiClient: APIClient
    private let database: DatabaseContainer
    private let previewCache: E2eeAttachmentPreviewCache
    private let operationQueue: OperationQueue
    private let flightRegistry = E2eeAttachmentPreviewFlightRegistry()

    init(
        apiClient: APIClient,
        database: DatabaseContainer,
        previewCache: E2eeAttachmentPreviewCache = .shared
    ) {
        self.apiClient = apiClient
        self.database = database
        self.previewCache = previewCache
        operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.e2ee.attachment-preview"
        operationQueue.qualityOfService = .utility
        operationQueue.maxConcurrentOperationCount = 3
    }

    func hydratePreviews(
        payload: E2ePayload,
        messageId: MessageId,
        cid: ChannelId,
        source: E2eeAttachmentReceiveSource
    ) {
        log.info(
            "[E2EE_ATTACHMENT_RECEIVE] operation=dispatch source=\(source.rawValue) manifest_count=\(payload.e2eeAttachments.count)",
            subsystems: .mls
        )
        for (index, manifest) in payload.e2eeAttachments.enumerated() {
            guard let preview = manifest.assets.first(where: { $0.kind == .preview }) else {
                log.error(
                    "[E2EE_ATTACHMENT_RECEIVE] operation=dispatch source=\(source.rawValue) state=missing_preview",
                    subsystems: .mls
                )
                continue
            }
            let target = E2eeAttachmentPreviewPersistenceTarget(
                manifest: manifest,
                previewAssetId: preview.assetId,
                attachmentId: AttachmentId(cid: cid, messageId: messageId, index: index)
            )
            if let cached = previewCache.value(for: preview.assetId) {
                persistRenderableAttachments(
                    [target],
                    previewGeneration: cached.generation,
                    source: source
                )
                continue
            }
            guard flightRegistry.register(assetId: preview.assetId, target: target) else {
                log.info(
                    "[E2EE_ATTACHMENT_RECEIVE] operation=preview source=\(source.rawValue) state=joined_existing_flight",
                    subsystems: .mls
                )
                continue
            }
            operationQueue.addOperation { [weak self] in
                guard let self else { return }
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    defer { semaphore.signal() }
                    do {
                        let data = try await self.downloadAndDecryptPreview(
                            manifest: manifest,
                            preview: preview,
                            cid: cid
                        )
                        let previewGeneration = self.previewCache.insert(data, for: preview.assetId)
                        let targets = self.flightRegistry.finish(assetId: preview.assetId)
                        await self.persistRenderableAttachmentsWithRetry(
                            targets,
                            previewGeneration: previewGeneration,
                            source: source
                        )
                        log.info(
                            "[E2EE_ATTACHMENT_RECEIVE] operation=preview source=\(source.rawValue) state=succeeded bytes=\(data.count) target_count=\(targets.count)",
                            subsystems: .mls
                        )
                    } catch {
                        _ = self.flightRegistry.finish(assetId: preview.assetId)
                        log.error(
                            "[E2EE_ATTACHMENT_RECEIVE] operation=preview source=\(source.rawValue) state=failed category=\(Self.errorCategory(error))",
                            subsystems: .mls
                        )
                    }
                }
                semaphore.wait()
            }
        }
    }

    private func downloadAndDecryptPreview(
        manifest: E2eeAttachmentManifestV1,
        preview: E2eeAttachmentManifestAssetV1,
        cid: ChannelId
    ) async throws -> Data {
        try manifest.validate()
        guard preview.kind == .preview else { throw E2eeAttachmentReceiveError.missingPreview }
        guard preview.cipherSize <= E2eeAttachmentFrameCryptoV1.previewCiphertextLimit else {
            throw E2eeAttachmentReceiveError.previewTooLarge
        }
        let grant = try await apiClient.e2eeAttachmentDownloadGrant(
            cid: cid,
            attachmentId: manifest.attachmentId,
            assetId: preview.assetId
        )
        let downloadedURL = try await downloadFile(from: grant.downloadURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErmisE2eeAttachmentPreview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cipherURL = directory.appendingPathComponent(UUID().uuidString + ".cipher")
        let plaintextURL = directory.appendingPathComponent(UUID().uuidString + ".preview")
        defer {
            try? FileManager.default.removeItem(at: downloadedURL)
            try? FileManager.default.removeItem(at: cipherURL)
            try? FileManager.default.removeItem(at: plaintextURL)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: cipherURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: cipherURL.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value == preview.cipherSize else {
            throw E2eeAttachmentReceiveError.cipherSizeMismatch
        }
        guard try sha256Hex(of: cipherURL).caseInsensitiveCompare(preview.cipherSha256) == .orderedSame else {
            throw E2eeAttachmentReceiveError.cipherHashMismatch
        }
        guard let contentKey = Data(base64Encoded: preview.contentKey),
              let noncePrefix = Data(base64Encoded: preview.noncePrefix) else {
            throw E2eeAttachmentReceiveError.invalidKeyMaterial
        }
        let result = try E2eeAttachmentFrameCryptoV1.decryptFile(
            at: cipherURL,
            to: plaintextURL,
            contentKey: contentKey,
            noncePrefix: noncePrefix,
            frameSize: Int(preview.frameSize)
        )
        guard result.ciphertextSize == preview.cipherSize,
              result.ciphertextSha256.caseInsensitiveCompare(preview.cipherSha256) == .orderedSame else {
            throw E2eeAttachmentReceiveError.cipherHashMismatch
        }
        if let expectedSize = preview.plaintextSize, result.plaintextSize != expectedSize {
            throw E2eeAttachmentReceiveError.plaintextSizeMismatch
        }
        if let expectedHash = preview.plaintextSha256,
           result.plaintextSha256.caseInsensitiveCompare(expectedHash) != .orderedSame {
            throw E2eeAttachmentReceiveError.plaintextHashMismatch
        }
        let data = try Data(contentsOf: plaintextURL, options: .mappedIfSafe)
        guard data.count <= Int(E2eeAttachmentFrameCryptoV1.previewCiphertextLimit) else {
            throw E2eeAttachmentReceiveError.previewTooLarge
        }
        return data
    }

    private func persistRenderableAttachments(
        _ targets: [E2eeAttachmentPreviewPersistenceTarget],
        previewGeneration: String,
        source: E2eeAttachmentReceiveSource
    ) {
        Task { [weak self] in
            await self?.persistRenderableAttachmentsWithRetry(
                targets,
                previewGeneration: previewGeneration,
                source: source
            )
        }
    }

    private func persistRenderableAttachmentsWithRetry(
        _ targets: [E2eeAttachmentPreviewPersistenceTarget],
        previewGeneration: String,
        source: E2eeAttachmentReceiveSource
    ) async {
        for target in targets {
            var attempt = 0
            while true {
                do {
                    try persistRenderableAttachment(
                        target,
                        previewGeneration: previewGeneration
                    )
                    if attempt > 0 {
                        log.info(
                            "[E2EE_ATTACHMENT_RECEIVE] operation=model source=\(source.rawValue) state=recovered attempt=\(attempt + 1)",
                            subsystems: .mls
                        )
                    }
                    break
                } catch {
                    guard Self.shouldRetryModelPersistence(error: error, attempt: attempt) else {
                        log.error(
                            "[E2EE_ATTACHMENT_RECEIVE] operation=model source=\(source.rawValue) state=failed category=\(Self.modelErrorCategory(error)) attempt=\(attempt + 1)",
                            subsystems: .mls
                        )
                        break
                    }
                    let delay = Self.modelPersistenceRetryDelayNanoseconds(attempt: attempt)
                    log.info(
                        "[E2EE_ATTACHMENT_RECEIVE] operation=model source=\(source.rawValue) state=waiting_for_message attempt=\(attempt + 1)",
                        subsystems: .mls
                    )
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    private func persistRenderableAttachment(
        _ target: E2eeAttachmentPreviewPersistenceTarget,
        previewGeneration: String
    ) throws {
        let renderable = try Self.renderablePayload(
            for: target.manifest,
            previewGeneration: previewGeneration
        )
        try database.writeAndWait { session in
            try session.saveE2eePreviewAttachment(
                id: target.attachmentId,
                type: renderable.type,
                payloadData: renderable.data,
                previewAssetId: target.previewAssetId
            )
        }
    }

    static func shouldRetryModelPersistence(error: Error, attempt: Int) -> Bool {
        error is ClientError.MessageDoesNotExist && attempt < 7
    }

    static func modelPersistenceRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        let delaysMilliseconds: [UInt64] = [50, 100, 200, 400, 800, 1_000, 1_000]
        return delaysMilliseconds[min(max(attempt, 0), delaysMilliseconds.count - 1)] * 1_000_000
    }

    private static func modelErrorCategory(_ error: Error) -> String {
        error is ClientError.MessageDoesNotExist ? "message_not_materialized" : "rendering"
    }

    static func renderablePayload(
        for manifest: E2eeAttachmentManifestV1,
        previewGeneration: String? = nil
    ) throws -> (type: AttachmentType, data: Data) {
        try manifest.validate()
        guard let original = manifest.assets.first(where: { $0.kind == .original }) else {
            throw E2eeAttachmentReceiveError.unsupportedMedia
        }
        let display = original.display ?? [:]
        let mimeType = display["mime_type"]?.stringValue?.lowercased()
        let title = display["name"]?.stringValue
        let width = display["width"]?.numberValue
        let height = display["height"]?.numberValue
        let duration = display["duration"]?.numberValue
        let file = AttachmentFile(
            type: AttachmentFileType(mimeType: mimeType ?? "application/octet-stream"),
            size: Int64(clamping: original.plaintextSize ?? 0),
            mimeType: mimeType
        )
        var opaqueComponents = URLComponents()
        opaqueComponents.scheme = "ermis-e2ee-attachment"
        opaqueComponents.host = "asset"
        opaqueComponents.path = "/\(manifest.attachmentId)/\(original.assetId)"
        if let previewGeneration {
            // The process-local preview cache is intentionally cleared on relaunch. A fresh,
            // non-sensitive generation makes the Core Data payload change after rehydration so
            // fetched-result observers rebuild the attachment with the newly cached bytes.
            opaqueComponents.queryItems = [
                URLQueryItem(name: "preview_generation", value: previewGeneration)
            ]
        }
        guard let opaqueURL = opaqueComponents.url else {
            throw E2eeAttachmentReceiveError.unsupportedMedia
        }
        let data: Data
        let type: AttachmentType
        if isVoiceRecording(display: display, mimeType: mimeType, duration: duration) {
            let waveform = display["waveform_data"]?.numberArrayValue?.map(Float.init)
            let payload = VoiceRecordingAttachmentPayload(
                title: title,
                voiceRecordingRemoteURL: opaqueURL,
                file: file,
                duration: duration,
                waveformData: waveform
            )
            data = try JSONEncoder.ermis.encode(payload)
            type = .voiceRecording
        } else if mimeType?.hasPrefix("video/") == true {
            var payload = VideoAttachmentPayload(
                title: title,
                videoRemoteURL: opaqueURL,
                thumbnailURL: nil,
                thumbnailData: nil,
                file: file
            )
            payload.duration = duration
            data = try JSONEncoder.ermis.encode(payload)
            type = .video
        } else if mimeType?.hasPrefix("image/") == true {
            let payload = ImageAttachmentPayload(
                title: title,
                imageRemoteURL: opaqueURL,
                file: file,
                thumbnailData: nil,
                originalWidth: width,
                originalHeight: height
            )
            data = try JSONEncoder.ermis.encode(payload)
            type = .image
        } else {
            let payload = FileAttachmentPayload(
                title: title,
                assetRemoteURL: opaqueURL,
                file: file
            )
            data = try JSONEncoder.ermis.encode(payload)
            type = .file
        }
        return (type, data)
    }

    /// The explicit marker is canonical. The fallback only repairs manifests emitted by the
    /// initial iOS implementation, which included audio MIME + voice duration but omitted the
    /// marker. Generic audio files do not carry this duration metadata and remain files.
    private static func isVoiceRecording(
        display: [String: RawJSON],
        mimeType: String?,
        duration: Double?
    ) -> Bool {
        if display["attachment_type"]?.stringValue == "voiceRecording" {
            return true
        }
        return display["attachment_type"] == nil
            && mimeType?.hasPrefix("audio/") == true
            && duration != nil
    }

    private func downloadFile(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: E2eeAttachmentReceiveError.invalidHTTPResponse)
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    continuation.resume(throwing: E2eeAttachmentReceiveError.invalidHTTPStatus(http.statusCode))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: E2eeAttachmentReceiveError.invalidHTTPResponse)
                    return
                }
                let retained = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".download")
                do {
                    try FileManager.default.moveItem(at: location, to: retained)
                    continuation.resume(returning: retained)
                } catch {
                    continuation.resume(throwing: error)
                }
            }.resume()
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func errorCategory(_ error: Error) -> String {
        guard let error = error as? E2eeAttachmentReceiveError else {
            return "download_or_decrypt"
        }
        switch error {
        case .cipherHashMismatch, .plaintextHashMismatch:
            return "integrity"
        case .cipherSizeMismatch, .plaintextSizeMismatch:
            return "size"
        case .invalidHTTPResponse, .invalidHTTPStatus:
            return "http"
        case .unsupportedMedia:
            return "unsupported_media"
        default:
            return "download_or_decrypt"
        }
    }
}
