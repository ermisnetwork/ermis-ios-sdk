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
    case channelInfo = "channel_info"
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
    struct Registration {
        let flightId: UUID
        let shouldStartFlight: Bool
    }

    struct WaiterRegistration {
        let id: UUID
        let flightId: UUID
        let shouldStartFlight: Bool
    }

    struct Waiter {
        let id: UUID
        let completion: (Result<Data, Error>) -> Void
    }

    struct FinishedFlight {
        let targets: [E2eeAttachmentPreviewPersistenceTarget]
        let waiters: [Waiter]
    }

    struct CancelledWaiter {
        let waiter: Waiter?
        let shouldCancelFlight: Bool
    }

    private struct Flight {
        let id: UUID
        var targets: [AttachmentId: E2eeAttachmentPreviewPersistenceTarget] = [:]
        var waiters: [UUID: Waiter] = [:]
    }

    private let lock = NSLock()
    private var flightsByAssetId: [String: Flight] = [:]

    /// Returns `true` only for the caller that must start the network request. Other callers join
    /// the existing request and are persisted when that request completes.
    func register(
        assetId: String,
        target: E2eeAttachmentPreviewPersistenceTarget
    ) -> Registration {
        lock.lock()
        defer { lock.unlock() }
        if var flight = flightsByAssetId[assetId] {
            flight.targets[target.attachmentId] = target
            flightsByAssetId[assetId] = flight
            return Registration(flightId: flight.id, shouldStartFlight: false)
        }
        let flight = Flight(id: UUID(), targets: [target.attachmentId: target])
        flightsByAssetId[assetId] = flight
        return Registration(flightId: flight.id, shouldStartFlight: true)
    }

    func registerWaiter(
        assetId: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> WaiterRegistration {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let waiter = Waiter(id: id, completion: completion)
        if var flight = flightsByAssetId[assetId] {
            flight.waiters[id] = waiter
            flightsByAssetId[assetId] = flight
            return WaiterRegistration(id: id, flightId: flight.id, shouldStartFlight: false)
        }
        let flight = Flight(id: UUID(), waiters: [id: waiter])
        flightsByAssetId[assetId] = flight
        return WaiterRegistration(id: id, flightId: flight.id, shouldStartFlight: true)
    }

    func cancelWaiter(assetId: String, flightId: UUID, id: UUID) -> CancelledWaiter {
        lock.lock()
        defer { lock.unlock() }
        guard var flight = flightsByAssetId[assetId], flight.id == flightId else {
            return CancelledWaiter(waiter: nil, shouldCancelFlight: false)
        }
        let waiter = flight.waiters.removeValue(forKey: id)
        let shouldCancelFlight = flight.waiters.isEmpty && flight.targets.isEmpty
        if shouldCancelFlight {
            flightsByAssetId.removeValue(forKey: assetId)
        } else {
            flightsByAssetId[assetId] = flight
        }
        return CancelledWaiter(waiter: waiter, shouldCancelFlight: shouldCancelFlight)
    }

    func finish(assetId: String, flightId: UUID) -> [E2eeAttachmentPreviewPersistenceTarget] {
        finishFlight(assetId: assetId, flightId: flightId).targets
    }

    func finishFlight(assetId: String, flightId: UUID) -> FinishedFlight {
        lock.lock()
        defer { lock.unlock() }
        guard let flight = flightsByAssetId[assetId], flight.id == flightId else {
            return FinishedFlight(targets: [], waiters: [])
        }
        flightsByAssetId.removeValue(forKey: assetId)
        return FinishedFlight(
            targets: Array(flight.targets.values),
            waiters: Array(flight.waiters.values)
        )
    }
}

private final class E2eeAttachmentPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var isCancelled = false

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

private final class E2eeAttachmentPreviewFlightWork: @unchecked Sendable {
    private let lock = NSLock()
    private weak var operation: Operation?
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func install(operation: Operation) {
        lock.lock()
        self.operation = operation
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { operation.cancel() }
    }

    func install(task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let operation = self.operation
        let task = self.task
        lock.unlock()
        operation?.cancel()
        task?.cancel()
    }
}

private struct E2eeAttachmentPreviewStoredFlightWork {
    let flightId: UUID
    let work: E2eeAttachmentPreviewFlightWork
}

/// Hydrates only encrypted preview assets for confirmed incoming E2EE messages. Original media is
/// intentionally not auto-downloaded; full original download/playback remains an explicit user
/// action and range streaming stays behind its independent feature gate.
final class E2eeAttachmentReceiveCoordinator {
    static let maximumConcurrentPreviewOperations = 3

    private let apiClient: APIClient
    private let database: DatabaseContainer
    private let previewCache: E2eeAttachmentPreviewCache
    private let operationQueue: OperationQueue
    private let flightRegistry = E2eeAttachmentPreviewFlightRegistry()
    private let flightWorkLock = NSLock()
    private var flightWorkByAssetId: [String: E2eeAttachmentPreviewStoredFlightWork] = [:]

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
        operationQueue.maxConcurrentOperationCount = Self.maximumConcurrentPreviewOperations
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
            let registration = flightRegistry.register(assetId: preview.assetId, target: target)
            guard registration.shouldStartFlight else {
                log.info(
                    "[E2EE_ATTACHMENT_RECEIVE] operation=preview source=\(source.rawValue) state=joined_existing_flight",
                    subsystems: .mls
                )
                continue
            }
            startPreviewFlight(
                manifest: manifest,
                preview: preview,
                cid: cid,
                source: source,
                flightId: registration.flightId
            )
        }
    }

    /// Loads exactly one manifest preview for a visible Channel Info cell. This joins the same
    /// bounded flight used by timeline/scope-sync hydration, and never falls back to the original.
    func loadPreview(
        manifest: E2eeAttachmentManifestV1,
        cid: ChannelId,
        source: E2eeAttachmentReceiveSource = .channelInfo
    ) async throws -> Data? {
        try manifest.validate()
        guard let preview = manifest.assets.first(where: { $0.kind == .preview }) else {
            return nil
        }
        if let cached = previewCache.value(for: preview.assetId) {
            return cached.data
        }

        let cancellation = E2eeAttachmentPreviewCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let registration = flightRegistry.registerWaiter(
                    assetId: preview.assetId,
                    completion: { result in
                        switch result {
                        case let .success(data):
                            continuation.resume(returning: data)
                        case let .failure(error):
                            continuation.resume(throwing: error)
                        }
                    }
                )
                cancellation.install { [weak self] in
                    self?.cancelPreviewWaiter(
                        assetId: preview.assetId,
                        flightId: registration.flightId,
                        id: registration.id
                    )
                }
                if registration.shouldStartFlight {
                    startPreviewFlight(
                        manifest: manifest,
                        preview: preview,
                        cid: cid,
                        source: source,
                        flightId: registration.flightId
                    )
                }
                if Task.isCancelled { cancellation.cancel() }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func startPreviewFlight(
        manifest: E2eeAttachmentManifestV1,
        preview: E2eeAttachmentManifestAssetV1,
        cid: ChannelId,
        source: E2eeAttachmentReceiveSource,
        flightId: UUID
    ) {
        let work = E2eeAttachmentPreviewFlightWork()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation, weak work] in
            guard let self, let operation, let work, !operation.isCancelled else { return }
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task { [weak self] in
                guard let self else {
                    semaphore.signal()
                    return
                }
                defer { semaphore.signal() }
                do {
                    let data = try await self.downloadAndDecryptPreview(
                        manifest: manifest,
                        preview: preview,
                        cid: cid
                    )
                    try Task.checkCancellation()
                    let previewGeneration = try self.previewCache.insert(data, for: preview.assetId)
                    let finished = self.flightRegistry.finishFlight(
                        assetId: preview.assetId,
                        flightId: flightId
                    )
                    self.removeFlightWork(assetId: preview.assetId, flightId: flightId)
                    await self.persistRenderableAttachmentsWithRetry(
                        finished.targets,
                        previewGeneration: previewGeneration,
                        source: source
                    )
                    finished.waiters.forEach { $0.completion(.success(data)) }
                    log.info(
                        "[E2EE_ATTACHMENT_RECEIVE] operation=preview source=\(source.rawValue) state=succeeded bytes=\(data.count) target_count=\(finished.targets.count) waiter_count=\(finished.waiters.count)",
                        subsystems: .mls
                    )
                } catch {
                    let finished = self.flightRegistry.finishFlight(
                        assetId: preview.assetId,
                        flightId: flightId
                    )
                    self.removeFlightWork(assetId: preview.assetId, flightId: flightId)
                    finished.waiters.forEach { $0.completion(.failure(error)) }
                    log.error(
                        "[E2EE_ATTACHMENT_RECEIVE] operation=preview source=\(source.rawValue) state=failed category=\(Self.errorCategory(error))",
                        subsystems: .mls
                    )
                }
            }
            work.install(task: task)
            semaphore.wait()
        }
        work.install(operation: operation)
        flightWorkLock.lock()
        flightWorkByAssetId[preview.assetId] = E2eeAttachmentPreviewStoredFlightWork(
            flightId: flightId,
            work: work
        )
        flightWorkLock.unlock()
        operationQueue.addOperation(operation)
    }

    private func cancelPreviewWaiter(assetId: String, flightId: UUID, id: UUID) {
        let cancelled = flightRegistry.cancelWaiter(
            assetId: assetId,
            flightId: flightId,
            id: id
        )
        cancelled.waiter?.completion(.failure(CancellationError()))
        guard cancelled.shouldCancelFlight else { return }
        flightWorkLock.lock()
        let storedWork = flightWorkByAssetId[assetId]
        let workToCancel: E2eeAttachmentPreviewFlightWork?
        if storedWork?.flightId == flightId {
            flightWorkByAssetId.removeValue(forKey: assetId)
            workToCancel = storedWork?.work
        } else {
            workToCancel = nil
        }
        flightWorkLock.unlock()
        workToCancel?.cancel()
    }

    private func removeFlightWork(assetId: String, flightId: UUID) {
        flightWorkLock.lock()
        if flightWorkByAssetId[assetId]?.flightId == flightId {
            flightWorkByAssetId.removeValue(forKey: assetId)
        }
        flightWorkLock.unlock()
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
        let (location, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw E2eeAttachmentReceiveError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw E2eeAttachmentReceiveError.invalidHTTPStatus(http.statusCode)
        }
        try Task.checkCancellation()
        let retained = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".download")
        try FileManager.default.moveItem(at: location, to: retained)
        return retained
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
