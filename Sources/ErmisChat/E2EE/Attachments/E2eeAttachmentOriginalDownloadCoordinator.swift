//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Public, non-sensitive progress for an explicit full-original E2EE attachment download.
///
/// `completedCiphertextBytes` measures bytes received from the attachment object store. The
/// original is only safe to use after the coordinator advances through `.verifying` and
/// `.decrypting`; callers must not treat `100%` network progress as a completed attachment.
public struct E2eeAttachmentOriginalDownloadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case queued
        case downloading
        case verifying
        case waitingForUnlock
        case decrypting
    }

    public let phase: Phase
    public let completedCiphertextBytes: UInt64
    public let totalCiphertextBytes: UInt64

    public var fractionCompleted: Double? {
        guard totalCiphertextBytes > 0 else { return nil }
        return min(1, Double(completedCiphertextBytes) / Double(totalCiphertextBytes))
    }

    public init(
        phase: Phase,
        completedCiphertextBytes: UInt64,
        totalCiphertextBytes: UInt64
    ) {
        self.phase = phase
        self.completedCiphertextBytes = completedCiphertextBytes
        self.totalCiphertextBytes = totalCiphertextBytes
    }
}

/// Transport-neutral spelling used by file-download UI shared by standard and E2EE channels.
/// For E2EE attachments the byte counters represent ciphertext; for standard attachments they
/// represent the directly downloaded file bytes.
public typealias AttachmentOriginalDownloadProgress = E2eeAttachmentOriginalDownloadProgress

/// Owns one consumer's access to a verified plaintext attachment original.
///
/// The local file remains valid until every lease for the same original is released. Gallery,
/// preview, Save, and Share therefore have independent ownership: dismissing a viewer cannot
/// invalidate an export that is still using the file. `release()` is idempotent and is also called
/// from `deinit` as a final safety net.
public final class E2eeAttachmentOriginalLease: @unchecked Sendable {
    public let localURL: URL

    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    init(localURL: URL, releaseHandler: @escaping @Sendable () -> Void) {
        self.localURL = localURL
        self.releaseHandler = releaseHandler
    }

    public func release() {
        lock.lock()
        let handler = releaseHandler
        releaseHandler = nil
        lock.unlock()
        handler?()
    }

    deinit {
        release()
    }
}

enum E2eeAttachmentOriginalDownloadError: Error {
    case invalidOpaqueURL
    case missingMessage
    case missingManifest
    case missingOriginal
    case invalidHTTPResponse
    case invalidHTTPStatus(Int)
    case insufficientStorage
    case cipherSizeMismatch
    case cipherHashMismatch
    case plaintextSizeMismatch
    case plaintextHashMismatch
    case invalidKeyMaterial
    case protectedDataUnavailable
    case backgroundTransferUnavailable
}

#if canImport(UIKit)
/// Suspends plaintext creation while iOS protected data is unavailable.
///
/// The verified ciphertext stays in Application Support during this wait. Cancellation removes
/// the notification observer but deliberately leaves that ciphertext available for a later retry.
@MainActor
private final class E2eeProtectedDataAvailabilityWaiter {
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isFinished = false

    func wait() async throws {
        if UIApplication.shared.isProtectedDataAvailable { return }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.continuation = continuation
                observer = NotificationCenter.default.addObserver(
                    forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.finish()
                    }
                }

                // Protected data can become available between the first check and observer
                // registration. Recheck after registration so that notification race cannot
                // leave the request suspended forever.
                if UIApplication.shared.isProtectedDataAvailable {
                    finish()
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(throwing: CancellationError())
            }
        })
    }

    private func finish(throwing error: Error? = nil) {
        guard !isFinished else { return }
        isFinished = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        let continuation = continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif

/// A host can construct more than one `ErmisClient` in the same process. Startup cleanup must
/// happen once per playback directory, otherwise constructing a second client could delete
/// plaintext that an active gallery owned by the first client is still reading.
final class E2eeAttachmentPlaintextLaunchCleanupRegistry: @unchecked Sendable {
    static let shared = E2eeAttachmentPlaintextLaunchCleanupRegistry()

    private let lock = NSLock()
    private var cleanedDirectoryPaths = Set<String>()

    func performOnce(directory: URL, cleanup: () throws -> Void) throws {
        let path = directory.standardizedFileURL.path
        lock.lock()
        guard cleanedDirectoryPaths.insert(path).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try cleanup()
        } catch {
            lock.lock()
            cleanedDirectoryPaths.remove(path)
            lock.unlock()
            throw error
        }
    }
}

/// Owns a foreground `URLSessionDownloadTask` and reports byte progress using the download
/// delegate callback. KVO on `URLSessionTask.progress` is intentionally avoided: it can publish
/// an initial unit count without matching the task's byte stream and previously caused some media
/// requests to remain stuck at that initial value.
final class AttachmentOriginalDownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    typealias DownloadResult = (URL, URLResponse)

    private let lock = NSLock()
    private let expectedCiphertextBytes: UInt64
    private let progress: @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    private let sessionConfiguration: URLSessionConfiguration

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var completedDownloadURL: URL?
    private var isCancelled = false

    init(
        expectedCiphertextBytes: UInt64,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) {
        self.expectedCiphertextBytes = expectedCiphertextBytes
        self.sessionConfiguration = sessionConfiguration
        self.progress = progress
        super.init()
    }

    func download(request: URLRequest) async throws -> DownloadResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = sessionConfiguration.copy() as? URLSessionConfiguration
                    ?? sessionConfiguration
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)

                lock.lock()
                if isCancelled {
                    lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.session = session
                self.task = task
                self.continuation = continuation
                lock.unlock()

                task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten >= 0 else { return }
        let responseBytes = totalBytesExpectedToWrite > 0
            ? UInt64(totalBytesExpectedToWrite)
            : 0
        let totalBytes = expectedCiphertextBytes > 0
            ? expectedCiphertextBytes
            : max(responseBytes, UInt64(totalBytesWritten))
        progress(.init(
            phase: .downloading,
            completedCiphertextBytes: min(UInt64(totalBytesWritten), totalBytes),
            totalCiphertextBytes: totalBytes
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let ownedTemporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErmisE2eeDownload-\(UUID().uuidString)", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: location, to: ownedTemporaryURL)
            lock.lock()
            completedDownloadURL = ownedTemporaryURL
            lock.unlock()
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        let downloadedURL = completedDownloadURL
        lock.unlock()
        guard let downloadedURL, let response = task.response else {
            finish(.failure(E2eeAttachmentOriginalDownloadError.invalidHTTPResponse))
            return
        }
        finish(.success((downloadedURL, response)))
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        let session = session
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    private func finish(_ result: Result<DownloadResult, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = session
        let downloadedURL = completedDownloadURL
        self.session = nil
        task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        if case .failure = result, let downloadedURL {
            try? FileManager.default.removeItem(at: downloadedURL)
        }
        continuation.resume(with: result)
    }
}

/// Scheduling is deliberately separate from the durable background upload coordinator. Originals
/// are foreground viewer work: only visible media should occupy its small interactive budget.
actor E2eeAttachmentOriginalDownloadScheduler {
    private struct Waiter {
        let token: UUID
        let sequence: UInt64
        let continuation: CheckedContinuation<UUID, Error>
    }

    private let maximumConcurrentDownloads: Int
    private var activeTokens = Set<UUID>()
    private var waiters: [UUID: Waiter] = [:]
    private var nextSequence: UInt64 = 0

    init(maximumConcurrentDownloads: Int = 2) {
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
    }

    func acquire() async throws -> UUID {
        let token = UUID()
        if activeTokens.count < maximumConcurrentDownloads, waiters.isEmpty {
            activeTokens.insert(token)
            return token
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                nextSequence &+= 1
                waiters[token] = Waiter(
                    token: token,
                    sequence: nextSequence,
                    continuation: continuation
                )
                resumeWaitersIfPossible()
            }
        }, onCancel: { [weak self] in
            Task {
                await self?.cancelWaiter(token)
            }
        })
    }

    func release(_ token: UUID) {
        guard activeTokens.remove(token) != nil else { return }
        resumeWaitersIfPossible()
    }

    private func cancelWaiter(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeWaitersIfPossible() {
        while activeTokens.count < maximumConcurrentDownloads,
              let next = waiters.values.min(by: { $0.sequence < $1.sequence }) {
            waiters[next.token] = nil
            activeTokens.insert(next.token)
            next.continuation.resume(returning: next.token)
        }
    }
}

/// Resolves an authenticated E2EE attachment manifest into a verified local plaintext file.
///
/// This is the full-download fallback required before range streaming is enabled. The original
/// remains ciphertext on the network and on the download staging path. Only after its declared
/// size and global SHA-256 match do we frame-decrypt it into the process-lifetime playback folder.
actor E2eeAttachmentOriginalDownloadCoordinator {
    typealias ProgressHandler = @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    typealias GrantURLProvider = @Sendable (ChannelId, String, String) async throws -> URL
    struct CiphertextDownloadInput: @unchecked Sendable {
        let request: URLRequest
        let expectedCiphertextBytes: UInt64
        let progress: ProgressHandler
    }
    typealias CiphertextDownloader = @Sendable (CiphertextDownloadInput) async throws -> (URL, URLResponse)
    struct DurableCiphertextInput: @unchecked Sendable {
        let cid: ChannelId
        let attachmentId: String
        let assetId: String
        let expectedCiphertextBytes: UInt64
        let expectedCiphertextSha256: String
        let progress: ProgressHandler
    }
    struct DurableCiphertextLease: @unchecked Sendable {
        let localURL: URL
        private let consumeHandler: @Sendable () async -> Void

        init(localURL: URL, consumeHandler: @escaping @Sendable () async -> Void) {
            self.localURL = localURL
            self.consumeHandler = consumeHandler
        }

        func consume() async {
            await consumeHandler()
        }
    }
    typealias DurableCiphertextProvider = @Sendable (DurableCiphertextInput) async throws -> DurableCiphertextLease
    typealias PlaintextPermissionWaiter = @Sendable (UInt64, ProgressHandler) async throws -> Void

    struct OpaqueAssetReference: Equatable, Sendable {
        let attachmentId: String
        let assetId: String
    }

    struct RangeStreamingDescriptor: Sendable {
        let cid: String
        let attachmentId: String
        let asset: E2eeAttachmentManifestAssetV1
    }

    private let database: DatabaseContainer
    private let fileManager: FileManager
    private let grantURLProvider: GrantURLProvider
    private let ciphertextDownloader: CiphertextDownloader
    private let durableCiphertextProvider: DurableCiphertextProvider?
    private let plaintextPermissionWaiter: PlaintextPermissionWaiter
    private let playbackDirectory: URL
    private let ciphertextDirectory: URL
    private let scheduler: E2eeAttachmentOriginalDownloadScheduler
    private var completedURLs: [String: URL] = [:]
    private var completedRequesterIds: [String: Set<UUID>] = [:]
    /// The URL-only compatibility API cannot express when its caller has finished reading the
    /// file. Keep those originals until shutdown while all SDK-owned viewers use leases.
    private var legacyRetainedCacheKeys = Set<String>()
    /// A full original download can be shared by multiple gallery cells. Keep explicit request
    /// ownership so dismissing one gallery can cancel its work without interrupting another
    /// viewer that is resolving the same asset.
    private struct InFlightDownload {
        let id: UUID
        let task: Task<URL, Error>
        var requesterIds: Set<UUID>
        var progressHandlers: [UUID: ProgressHandler]
        var latestProgress: E2eeAttachmentOriginalDownloadProgress?
    }

    private var inFlight: [String: InFlightDownload] = [:]

    init(
        apiClient: APIClient,
        database: DatabaseContainer,
        fileManager: FileManager = .default,
        ciphertextDirectory: URL? = nil,
        playbackDirectory: URL? = nil,
        grantURLProvider: GrantURLProvider? = nil,
        ciphertextDownloader: CiphertextDownloader? = nil,
        durableCiphertextProvider: DurableCiphertextProvider? = nil,
        plaintextPermissionWaiter: PlaintextPermissionWaiter? = nil
    ) {
        self.init(
            database: database,
            fileManager: fileManager,
            ciphertextDirectory: ciphertextDirectory,
            playbackDirectory: playbackDirectory,
            grantURLProvider: grantURLProvider ?? { cid, attachmentId, assetId in
                try await apiClient.e2eeAttachmentDownloadGrant(
                    cid: cid,
                    attachmentId: attachmentId,
                    assetId: assetId
                ).downloadURL
            },
            ciphertextDownloader: ciphertextDownloader ?? { input in
                try await Self.downloadCiphertext(
                    request: input.request,
                    expectedCiphertextBytes: input.expectedCiphertextBytes,
                    progress: input.progress
                )
            },
            durableCiphertextProvider: durableCiphertextProvider,
            plaintextPermissionWaiter: plaintextPermissionWaiter ?? { ciphertextSize, progress in
                try await Self.waitForPlaintextCreationPermission(
                    ciphertextSize: ciphertextSize,
                    progress: progress
                )
            }
        )
    }

    /// Internal construction seam for deterministic full-download contract tests. The live SDK
    /// initializer above still owns Bellboy grants and URLSession; this overload only replaces
    /// those two I/O boundaries and never changes the public attachment API.
    init(
        database: DatabaseContainer,
        fileManager: FileManager = .default,
        ciphertextDirectory: URL? = nil,
        playbackDirectory: URL? = nil,
        grantURLProvider: @escaping GrantURLProvider,
        ciphertextDownloader: @escaping CiphertextDownloader,
        durableCiphertextProvider: DurableCiphertextProvider? = nil,
        plaintextPermissionWaiter: @escaping PlaintextPermissionWaiter
    ) {
        self.database = database
        self.fileManager = fileManager
        self.grantURLProvider = grantURLProvider
        self.ciphertextDownloader = ciphertextDownloader
        self.durableCiphertextProvider = durableCiphertextProvider
        self.plaintextPermissionWaiter = plaintextPermissionWaiter
        scheduler = E2eeAttachmentOriginalDownloadScheduler()
        self.playbackDirectory = playbackDirectory ?? Self.defaultPlaybackDirectory(fileManager: fileManager)
        self.ciphertextDirectory = ciphertextDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("ErmisE2eeAttachmentCiphertext", isDirectory: true)

        // Startup cleanup is wired eagerly from ErmisClient. The lazy coordinator must only
        // ensure the directory exists; resetting it here could delete an active second client's
        // plaintext in the same process.
        try? Self.prepareDirectory(self.playbackDirectory, fileManager: fileManager)
    }

    /// Cancels foreground viewer work and removes process-lifetime plaintext originals.
    ///
    /// This is intentionally scoped to the original-download fallback. It does not touch durable
    /// ciphertext upload staging or background URLSession work, which follow their own account
    /// scoped lifecycle.
    func shutdown() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        completedURLs.removeAll()
        completedRequesterIds.removeAll()
        legacyRetainedCacheKeys.removeAll()
        try? fileManager.removeItem(at: playbackDirectory)
    }

    func localOriginalLease(
        for attachment: AnyMessageAttachment,
        progress: @escaping ProgressHandler
    ) async throws -> E2eeAttachmentOriginalLease {
        guard let remoteURL = attachment.remoteURL else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        guard remoteURL.scheme == Self.opaqueScheme else {
            return E2eeAttachmentOriginalLease(localURL: remoteURL, releaseHandler: {})
        }

        let reference = try Self.parseReference(remoteURL)
        let cacheKey = reference.assetId.lowercased()
        let requesterId = UUID()
        let localURL = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await self.waitForOriginal(
                attachment: attachment,
                reference: reference,
                cacheKey: cacheKey,
                requesterId: requesterId,
                progress: progress
            )
        }, onCancel: { [weak self] in
            Task {
                await self?.cancelOriginalRequest(cacheKey: cacheKey, requesterId: requesterId)
            }
        })

        completedRequesterIds[cacheKey, default: []].insert(requesterId)
        do {
            try Task.checkCancellation()
        } catch {
            releaseCompletedOriginal(cacheKey: cacheKey, requesterId: requesterId)
            throw error
        }
        return E2eeAttachmentOriginalLease(localURL: localURL) { [weak self] in
            Task {
                await self?.releaseCompletedOriginal(cacheKey: cacheKey, requesterId: requesterId)
            }
        }
    }

    func localOriginalURL(
        for attachment: AnyMessageAttachment,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        guard let remoteURL = attachment.remoteURL else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        guard remoteURL.scheme == Self.opaqueScheme else { return remoteURL }

        let reference = try Self.parseReference(remoteURL)
        let cacheKey = reference.assetId.lowercased()
        if let completedURL = completedURLs[cacheKey],
           fileManager.fileExists(atPath: completedURL.path) {
            legacyRetainedCacheKeys.insert(cacheKey)
            return completedURL
        }

        let requesterId = UUID()
        let url = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await self.waitForOriginal(
                attachment: attachment,
                reference: reference,
                cacheKey: cacheKey,
                requesterId: requesterId,
                progress: progress
            )
        }, onCancel: { [weak self] in
            // `Task.value` does not by itself cancel the unstructured task stored by the actor.
            // Hop back to the actor so the final viewer actively cancels the URLSession request.
            Task {
                await self?.cancelOriginalRequest(cacheKey: cacheKey, requesterId: requesterId)
            }
        })
        legacyRetainedCacheKeys.insert(cacheKey)
        return url
    }

    func rangeStreamingDescriptor(
        for attachment: AnyMessageAttachment
    ) async throws -> RangeStreamingDescriptor {
        let reference = try Self.opaqueAssetReference(for: attachment)
        let manifest = try await Self.loadManifest(
            messageId: attachment.id.messageId,
            attachmentIndex: attachment.id.index,
            reference: reference,
            database: database
        )
        try manifest.validate()
        guard let original = manifest.assets.first(where: {
            $0.kind == .original &&
                $0.assetId.caseInsensitiveCompare(reference.assetId) == .orderedSame
        }), original.plaintextSize != nil else {
            throw E2eeAttachmentOriginalDownloadError.missingOriginal
        }
        return .init(
            cid: attachment.id.cid.rawValue,
            attachmentId: reference.attachmentId,
            asset: original
        )
    }

    nonisolated static func isOpaqueE2eeAttachment(_ attachment: AnyMessageAttachment) -> Bool {
        attachment.remoteURL?.scheme?.lowercased() == opaqueScheme
    }

    nonisolated static func shouldRenewGrant(afterHTTPStatus statusCode: Int, grantAttempt: Int) -> Bool {
        (statusCode == 401 || statusCode == 403) && grantAttempt == 0
    }

    private func waitForOriginal(
        attachment: AnyMessageAttachment,
        reference: OpaqueAssetReference,
        cacheKey: String,
        requesterId: UUID,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        if let completedURL = completedURLs[cacheKey],
           fileManager.fileExists(atPath: completedURL.path) {
            return completedURL
        }

        let activeDownload: InFlightDownload
        if var existing = inFlight[cacheKey] {
            existing.requesterIds.insert(requesterId)
            existing.progressHandlers[requesterId] = progress
            inFlight[cacheKey] = existing
            if let latestProgress = existing.latestProgress {
                progress(latestProgress)
            }
            activeDownload = existing
        } else {
            let database = database
            let fileManager = fileManager
            let playbackDirectory = playbackDirectory
            let ciphertextDirectory = ciphertextDirectory
            let grantURLProvider = grantURLProvider
            let ciphertextDownloader = ciphertextDownloader
            let durableCiphertextProvider = durableCiphertextProvider
            let plaintextPermissionWaiter = plaintextPermissionWaiter
            let attachmentId = attachment.id
            let scheduler = scheduler
            let downloadId = UUID()
            let coordinator = self
            let task = Task<URL, Error>(priority: .userInitiated) {
                try Task.checkCancellation()
                let schedulerToken = try await scheduler.acquire()
                do {
                    try Task.checkCancellation()
                    let url = try await Self.downloadOriginal(
                        attachmentId: attachmentId,
                        reference: reference,
                        database: database,
                        fileManager: fileManager,
                        playbackDirectory: playbackDirectory,
                        ciphertextDirectory: ciphertextDirectory,
                        grantURLProvider: grantURLProvider,
                        ciphertextDownloader: ciphertextDownloader,
                        durableCiphertextProvider: durableCiphertextProvider,
                        plaintextPermissionWaiter: plaintextPermissionWaiter,
                        progress: { update in
                            Task {
                                await coordinator.publishOriginalDownloadProgress(
                                    update,
                                    cacheKey: cacheKey,
                                    downloadId: downloadId
                                )
                            }
                        }
                    )
                    await scheduler.release(schedulerToken)
                    return url
                } catch {
                    await scheduler.release(schedulerToken)
                    throw error
                }
            }
            activeDownload = InFlightDownload(
                id: downloadId,
                task: task,
                requesterIds: [requesterId],
                progressHandlers: [requesterId: progress],
                latestProgress: .init(
                    phase: .queued,
                    completedCiphertextBytes: 0,
                    totalCiphertextBytes: 0
                )
            )
            inFlight[cacheKey] = activeDownload
            if let initialProgress = activeDownload.latestProgress {
                progress(initialProgress)
            }
        }

        do {
            let url = try await activeDownload.task.value
            try Task.checkCancellation()
            if inFlight[cacheKey]?.id == activeDownload.id {
                inFlight[cacheKey] = nil
            }
            completedURLs[cacheKey] = url
            return url
        } catch {
            if inFlight[cacheKey]?.id == activeDownload.id {
                inFlight[cacheKey] = nil
            }

            // A new viewer can arrive while the previous viewer's cancellation is still being
            // propagated into URLSession. That new viewer must start a fresh request rather than
            // inheriting the canceled task and remaining on an indefinite loading state.
            if error is CancellationError, !Task.isCancelled {
                return try await waitForOriginal(
                    attachment: attachment,
                    reference: reference,
                    cacheKey: cacheKey,
                    requesterId: requesterId,
                    progress: progress
                )
            }
            throw error
        }
    }

    private func cancelOriginalRequest(cacheKey: String, requesterId: UUID) {
        guard var activeDownload = inFlight[cacheKey],
              activeDownload.requesterIds.remove(requesterId) != nil else {
            return
        }

        activeDownload.progressHandlers[requesterId] = nil
        inFlight[cacheKey] = activeDownload
        guard activeDownload.requesterIds.isEmpty else { return }

        log.info(
            "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=detaching reason=no_active_viewer durable_transport=\(durableCiphertextProvider != nil)",
            subsystems: .mls
        )
        // This only cancels the current consumer and its polling/decrypt wrapper. When the live
        // durable provider is configured, the SDK-owned background URLSession task keeps running
        // and will be reused by the next viewer or after process relaunch.
        activeDownload.task.cancel()
    }

    private func releaseCompletedOriginal(cacheKey: String, requesterId: UUID) {
        guard var requesterIds = completedRequesterIds[cacheKey],
              requesterIds.remove(requesterId) != nil else {
            return
        }

        if requesterIds.isEmpty {
            completedRequesterIds[cacheKey] = nil
        } else {
            completedRequesterIds[cacheKey] = requesterIds
            return
        }

        guard !legacyRetainedCacheKeys.contains(cacheKey),
              let localURL = completedURLs.removeValue(forKey: cacheKey) else {
            return
        }
        try? fileManager.removeItem(at: localURL)
        log.info(
            "[E2EE_ATTACHMENT_DOWNLOAD] operation=plaintext_cleanup state=completed reason=last_consumer_released",
            subsystems: .mls
        )
    }

    private func publishOriginalDownloadProgress(
        _ progress: E2eeAttachmentOriginalDownloadProgress,
        cacheKey: String,
        downloadId: UUID
    ) {
        guard var activeDownload = inFlight[cacheKey], activeDownload.id == downloadId else {
            return
        }
        activeDownload.latestProgress = progress
        let handlers = activeDownload.progressHandlers.values
        inFlight[cacheKey] = activeDownload
        handlers.forEach { $0(progress) }
    }

    private static func downloadOriginal(
        attachmentId: AttachmentId,
        reference: OpaqueAssetReference,
        database: DatabaseContainer,
        fileManager: FileManager,
        playbackDirectory: URL,
        ciphertextDirectory: URL,
        grantURLProvider: @escaping GrantURLProvider,
        ciphertextDownloader: @escaping CiphertextDownloader,
        durableCiphertextProvider: DurableCiphertextProvider?,
        plaintextPermissionWaiter: @escaping PlaintextPermissionWaiter,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) async throws -> URL {
        let startedAt = Date()
        try Task.checkCancellation()
        let manifest = try await loadManifest(
            messageId: attachmentId.messageId,
            attachmentIndex: attachmentId.index,
            reference: reference,
            database: database
        )
        try Task.checkCancellation()
        try manifest.validate()
        guard let original = manifest.assets.first(where: {
            $0.kind == .original && $0.assetId.caseInsensitiveCompare(reference.assetId) == .orderedSame
        }) else {
            throw E2eeAttachmentOriginalDownloadError.missingOriginal
        }
        progress(.init(
            phase: .downloading,
            completedCiphertextBytes: 0,
            totalCiphertextBytes: original.cipherSize
        ))
        try prepareDirectory(playbackDirectory, fileManager: fileManager)
        try prepareDirectory(ciphertextDirectory, fileManager: fileManager)

        let opaqueName = SHA256.hash(data: Data(original.assetId.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        let cipherPartialURL = ciphertextDirectory.appendingPathComponent(opaqueName + ".cipher.partial")
        let verifiedCipherURL = ciphertextDirectory.appendingPathComponent(opaqueName + ".cipher")
        let plaintextURL = playbackDirectory.appendingPathComponent(
            opaqueName + "." + preferredExtension(for: original)
        )
        let plaintextPartialURL = plaintextURL.appendingPathExtension("partial")
        try? fileManager.removeItem(at: plaintextURL)
        try? fileManager.removeItem(at: plaintextPartialURL)

        // A verified ciphertext is intentionally durable across viewer cancellation, lock state,
        // decrypt ENOSPC, and process relaunch. Validate it again after relaunch before reuse.
        var hasVerifiedCiphertext = false
        var ciphertextForDecryptionURL = verifiedCipherURL
        var durableCiphertextLease: DurableCiphertextLease?
        if fileManager.fileExists(atPath: verifiedCipherURL.path) {
            do {
                try validateCiphertext(
                    at: verifiedCipherURL,
                    expectedSize: original.cipherSize,
                    expectedSHA256: original.cipherSha256,
                    fileManager: fileManager,
                    progress: progress
                )
                hasVerifiedCiphertext = true
            } catch {
                if error is CancellationError { throw error }
                try? fileManager.removeItem(at: verifiedCipherURL)
            }
        }

        // A retry that already owns globally verified ciphertext only needs enough room for the
        // plaintext output and safety reserve. Charging the ciphertext a second time can otherwise
        // permanently block recovery from an earlier decrypt/export ENOSPC failure.
        try preflightStorage(
            for: original,
            directory: ciphertextDirectory,
            requiresCiphertextStaging: !hasVerifiedCiphertext
        )

        if !hasVerifiedCiphertext, let durableCiphertextProvider {
            do {
                let lease = try await durableCiphertextProvider(.init(
                    cid: attachmentId.cid,
                    attachmentId: manifest.attachmentId,
                    assetId: original.assetId,
                    expectedCiphertextBytes: original.cipherSize,
                    expectedCiphertextSha256: original.cipherSha256,
                    progress: progress
                ))
                try Task.checkCancellation()
                durableCiphertextLease = lease
                ciphertextForDecryptionURL = lease.localURL
                hasVerifiedCiphertext = true
            } catch {
                let classifiedError = classifyDiskError(error, stage: .download)
                log.error(
                    "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=failed stage=background_download category=\(errorCategory(classifiedError))",
                    subsystems: .mls
                )
                throw classifiedError
            }
        } else if !hasVerifiedCiphertext {
            try? fileManager.removeItem(at: cipherPartialURL)
            do {
                let temporaryDownloadURL = try await downloadCiphertextWithGrantRenewal(
                    attachmentId: attachmentId,
                    manifestAttachmentId: manifest.attachmentId,
                    assetId: original.assetId,
                    expectedCiphertextBytes: original.cipherSize,
                    grantURLProvider: grantURLProvider,
                    ciphertextDownloader: ciphertextDownloader,
                    progress: progress
                )
                // URLSession owns its original location. The delegate moved it to an operation-
                // owned URL, which still needs deterministic cleanup at every cancellation edge.
                defer { try? fileManager.removeItem(at: temporaryDownloadURL) }
                try Task.checkCancellation()
                try fileManager.moveItem(at: temporaryDownloadURL, to: cipherPartialURL)
                try applyFileProtection(to: cipherPartialURL, fileManager: fileManager)
                try validateCiphertext(
                    at: cipherPartialURL,
                    expectedSize: original.cipherSize,
                    expectedSHA256: original.cipherSha256,
                    fileManager: fileManager,
                    progress: progress
                )
                try? fileManager.removeItem(at: verifiedCipherURL)
                try fileManager.moveItem(at: cipherPartialURL, to: verifiedCipherURL)
                hasVerifiedCiphertext = true
                // Promotion makes the byte-identical, globally verified ciphertext retryable.
                // A dismissal at this boundary must not force another object-store download.
                try Task.checkCancellation()
            } catch {
                try? fileManager.removeItem(at: cipherPartialURL)
                let classifiedError = classifyDiskError(error, stage: .download)
                log.error(
                    "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=failed stage=download category=\(errorCategory(classifiedError))",
                    subsystems: .mls
                )
                throw classifiedError
            }
        }

#if DEBUG
        if E2eeR2RangeProofGate.shared.claim() {
            log.info(
                "[E2EE_R2_RANGE_PROOF] state=started full_cipher_sha256=verified",
                subsystems: .mls
            )
            do {
                // Do not trust the provider label alone for this release proof. Re-read the exact
                // comparison source and prove its complete size/global hash immediately before
                // asking R2 for one raw byte range.
                try validateCiphertext(
                    at: ciphertextForDecryptionURL,
                    expectedSize: original.cipherSize,
                    expectedSHA256: original.cipherSha256,
                    fileManager: fileManager,
                    progress: progress
                )
                let proofGrantURL = try await grantURLProvider(
                    attachmentId.cid,
                    manifest.attachmentId,
                    original.assetId
                )
                let proof = try await E2eeR2RangeProofVerifier.verify(
                    grantURL: proofGrantURL,
                    verifiedCiphertextURL: ciphertextForDecryptionURL,
                    totalCiphertextSize: original.cipherSize
                )
                log.info(
                    "[E2EE_R2_RANGE_PROOF] state=succeeded status=206 content_length=exact content_range=exact body=identical bytes=\(proof.byteCount)",
                    subsystems: .mls
                )
            } catch {
                let category = (error as? E2eeR2RangeProofError)?.category
                    ?? "prerequisite_or_transport"
                log.error(
                    "[E2EE_R2_RANGE_PROOF] state=failed category=\(category)",
                    subsystems: .mls
                )
                throw E2eeAttachmentOriginalDownloadError.invalidHTTPResponse
            }
        }
#endif

        try await plaintextPermissionWaiter(original.cipherSize, progress)
        do {
            try Task.checkCancellation()
            guard let contentKey = Data(base64Encoded: original.contentKey),
                  let noncePrefix = Data(base64Encoded: original.noncePrefix) else {
                throw E2eeAttachmentOriginalDownloadError.invalidKeyMaterial
            }

            progress(.init(
                phase: .decrypting,
                completedCiphertextBytes: original.cipherSize,
                totalCiphertextBytes: original.cipherSize
            ))
            let result = try E2eeAttachmentFrameCryptoV1.decryptFile(
                at: ciphertextForDecryptionURL,
                to: plaintextPartialURL,
                contentKey: contentKey,
                noncePrefix: noncePrefix,
                frameSize: Int(original.frameSize)
            )
            try Task.checkCancellation()
            guard result.ciphertextSize == original.cipherSize,
                  result.ciphertextSha256.caseInsensitiveCompare(original.cipherSha256) == .orderedSame else {
                throw E2eeAttachmentOriginalDownloadError.cipherHashMismatch
            }
            if let expectedSize = original.plaintextSize,
               result.plaintextSize != expectedSize {
                throw E2eeAttachmentOriginalDownloadError.plaintextSizeMismatch
            }
            if let expectedHash = original.plaintextSha256,
               result.plaintextSha256.caseInsensitiveCompare(expectedHash) != .orderedSame {
                throw E2eeAttachmentOriginalDownloadError.plaintextHashMismatch
            }
            try applyFileProtection(to: plaintextPartialURL, fileManager: fileManager)
            // Plaintext becomes visible to gallery/export consumers only after every authenticated
            // size/hash check succeeds. The rename is atomic because both paths share a volume.
            try fileManager.moveItem(at: plaintextPartialURL, to: plaintextURL)
            if let durableCiphertextLease {
                await durableCiphertextLease.consume()
            } else {
                try? fileManager.removeItem(at: verifiedCipherURL)
            }
            log.info(
                "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=succeeded plaintext_bytes=\(result.plaintextSize) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))",
                subsystems: .mls
            )
            return plaintextURL
        } catch {
            try? fileManager.removeItem(at: plaintextURL)
            try? fileManager.removeItem(at: plaintextPartialURL)
            let classifiedError = classifyDiskError(error, stage: .export)
            if !shouldRetainVerifiedCiphertext(after: classifiedError) {
                if let durableCiphertextLease {
                    await durableCiphertextLease.consume()
                } else {
                    try? fileManager.removeItem(at: verifiedCipherURL)
                }
            }
            log.error(
                "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=failed stage=decrypt category=\(errorCategory(classifiedError)) retained_cipher=\(shouldRetainVerifiedCiphertext(after: classifiedError))",
                subsystems: .mls
            )
            throw classifiedError
        }
    }

    /// A presigned GET that reaches 401/403 may have expired between grant issuance and storage
    /// access. Renew once and restart the complete GET; partial ciphertext is never reused without
    /// range proof. Other failures keep their exact category and are not retried here.
    private static func downloadCiphertextWithGrantRenewal(
        attachmentId: AttachmentId,
        manifestAttachmentId: String,
        assetId: String,
        expectedCiphertextBytes: UInt64,
        grantURLProvider: @escaping GrantURLProvider,
        ciphertextDownloader: @escaping CiphertextDownloader,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) async throws -> URL {
        for grantAttempt in 0...1 {
            try Task.checkCancellation()
            log.info(
                "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=grant_requesting attempt=\(grantAttempt + 1) cipher_bytes=\(expectedCiphertextBytes)",
                subsystems: .mls
            )
            let grantURL = try await grantURLProvider(
                attachmentId.cid,
                manifestAttachmentId,
                assetId
            )
            try Task.checkCancellation()

            var request = URLRequest(url: grantURL)
            request.httpMethod = "GET"
            let (temporaryURL, response) = try await ciphertextDownloader(.init(
                request: request,
                expectedCiphertextBytes: expectedCiphertextBytes,
                progress: progress
            ))
            do {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw E2eeAttachmentOriginalDownloadError.invalidHTTPResponse
                }
                if (200..<300).contains(http.statusCode) {
                    return temporaryURL
                }
                if shouldRenewGrant(afterHTTPStatus: http.statusCode, grantAttempt: grantAttempt) {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    log.info(
                        "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=grant_renewing reason=unauthorized",
                        subsystems: .mls
                    )
                    continue
                }
                throw E2eeAttachmentOriginalDownloadError.invalidHTTPStatus(http.statusCode)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
        throw E2eeAttachmentOriginalDownloadError.invalidHTTPStatus(403)
    }

    private static func downloadCiphertext(
        request: URLRequest,
        expectedCiphertextBytes: UInt64,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = AttachmentOriginalDownloadDelegate(
            expectedCiphertextBytes: expectedCiphertextBytes,
            progress: progress
        )
        return try await delegate.download(request: request)
    }

    private static func loadManifest(
        messageId: MessageId,
        attachmentIndex: Int,
        reference: OpaqueAssetReference,
        database: DatabaseContainer
    ) async throws -> E2eeAttachmentManifestV1 {
        try await withCheckedThrowingContinuation { continuation in
            let context = database.backgroundReadOnlyContext
            context.perform {
                guard let message = context.message(id: messageId),
                      let decrypted = message.decryptedMessage else {
                    continuation.resume(throwing: E2eeAttachmentOriginalDownloadError.missingMessage)
                    return
                }
                do {
                    let payload = try decrypted.asPayload()
                    let indexed = payload.e2eeAttachments.indices.contains(attachmentIndex)
                        ? payload.e2eeAttachments[attachmentIndex]
                        : nil
                    let manifest = indexed?.attachmentId.caseInsensitiveCompare(reference.attachmentId) == .orderedSame
                        ? indexed
                        : payload.e2eeAttachments.first {
                            $0.attachmentId.caseInsensitiveCompare(reference.attachmentId) == .orderedSame
                        }
                    guard let manifest else {
                        throw E2eeAttachmentOriginalDownloadError.missingManifest
                    }
                    continuation.resume(returning: manifest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let opaqueScheme = "ermis-e2ee-attachment"

    nonisolated static func opaqueAssetReference(
        for attachment: AnyMessageAttachment
    ) throws -> OpaqueAssetReference {
        guard let remoteURL = attachment.remoteURL else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        return try parseReference(remoteURL)
    }

    nonisolated private static func parseReference(_ url: URL) throws -> OpaqueAssetReference {
        guard url.scheme == opaqueScheme,
              url.host == "asset" else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2,
              UUID(uuidString: components[0]) != nil,
              UUID(uuidString: components[1]) != nil else {
            throw E2eeAttachmentOriginalDownloadError.invalidOpaqueURL
        }
        return OpaqueAssetReference(attachmentId: components[0], assetId: components[1])
    }

    private static func preferredExtension(for asset: E2eeAttachmentManifestAssetV1) -> String {
        if let name = asset.display?["name"]?.stringValue {
            let value = URL(fileURLWithPath: name).pathExtension.lowercased()
            if !value.isEmpty, value.count <= 8 { return value }
        }
        switch asset.display?["mime_type"]?.stringValue?.lowercased() {
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "audio/aac": return "aac"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        case "audio/webm": return "webm"
        default: return "mp4"
        }
    }

    private static func preflightStorage(
        for asset: E2eeAttachmentManifestAssetV1,
        directory: URL,
        requiresCiphertextStaging: Bool = true
    ) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let plaintext = asset.plaintextSize ?? asset.cipherSize
        guard let required = requiredStorageBytes(
            ciphertextSize: asset.cipherSize,
            plaintextSize: plaintext,
            requiresCiphertextStaging: requiresCiphertextStaging
        ), UInt64(max(0, available)) >= required else {
            throw E2eeAttachmentOriginalDownloadError.insufficientStorage
        }
    }

    static func requiredStorageBytes(
        ciphertextSize: UInt64,
        plaintextSize: UInt64,
        requiresCiphertextStaging: Bool,
        reserveBytes: UInt64 = 100 * 1024 * 1024
    ) -> UInt64? {
        let ciphertext = requiresCiphertextStaging ? ciphertextSize : 0
        let output = ciphertext.addingReportingOverflow(plaintextSize)
        guard !output.overflow else { return nil }
        let reserved = output.partialValue.addingReportingOverflow(reserveBytes)
        return reserved.overflow ? nil : reserved.partialValue
    }

    private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    private static func applyFileProtection(to url: URL, fileManager: FileManager) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    private static func validateCiphertext(
        at url: URL,
        expectedSize: UInt64,
        expectedSHA256: String,
        fileManager: FileManager,
        progress: @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value == expectedSize else {
            throw E2eeAttachmentOriginalDownloadError.cipherSizeMismatch
        }
        progress(.init(
            phase: .verifying,
            completedCiphertextBytes: expectedSize,
            totalCiphertextBytes: expectedSize
        ))
        guard try sha256Hex(of: url).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw E2eeAttachmentOriginalDownloadError.cipherHashMismatch
        }
    }

    private static func waitForPlaintextCreationPermission(
        ciphertextSize: UInt64,
        progress: @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void
    ) async throws {
#if canImport(UIKit)
        let isAvailable = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard !isAvailable else { return }

        progress(.init(
            phase: .waitingForUnlock,
            completedCiphertextBytes: ciphertextSize,
            totalCiphertextBytes: ciphertextSize
        ))
        log.info(
            "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=waiting_for_unlock retained_cipher=true",
            subsystems: .mls
        )
        let waiter = await MainActor.run { E2eeProtectedDataAvailabilityWaiter() }
        try await waiter.wait()
        try Task.checkCancellation()
        log.info(
            "[E2EE_ATTACHMENT_DOWNLOAD] operation=original state=unlock_available",
            subsystems: .mls
        )
#endif
    }

    static func shouldRetainVerifiedCiphertext(after error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let downloadError = error as? E2eeAttachmentOriginalDownloadError else {
            return false
        }
        switch downloadError {
        case .insufficientStorage, .protectedDataUnavailable:
            return true
        default:
            return false
        }
    }

    static func defaultPlaybackDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("ErmisE2eeAttachmentPlayback", isDirectory: true)
    }

    /// Called eagerly by the main app at SDK-client construction. It is process-idempotent so a
    /// second client cannot invalidate an active gallery owned by the first client.
    static func cleanupStalePlaintextAtMainAppLaunch(fileManager: FileManager = .default) throws {
        let directory = defaultPlaybackDirectory(fileManager: fileManager)
        try E2eeAttachmentPlaintextLaunchCleanupRegistry.shared.performOnce(directory: directory) {
            try resetPlaybackDirectory(directory, fileManager: fileManager)
        }
    }

    /// Removes plaintext left by a terminated player process and recreates the protected,
    /// excluded-from-backup playback directory. This runs for every new SDK client, regardless of
    /// whether the previous process exited normally, was killed by iOS, or crashed.
    static func resetPlaybackDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try prepareDirectory(url, fileManager: fileManager)
    }

    static func classifyDiskError(
        _ error: Error,
        stage: E2eeAttachmentDiskStage
    ) -> Error {
        let classified = E2eeAttachmentStagingStore.classifyDiskError(error, stage: stage)
        guard let stagingError = classified as? E2eeAttachmentStagingError,
              case .noSpace = stagingError else {
            return classified
        }
        return E2eeAttachmentOriginalDownloadError.insufficientStorage
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case E2eeAttachmentOriginalDownloadError.cipherHashMismatch,
             E2eeAttachmentOriginalDownloadError.plaintextHashMismatch:
            return "integrity"
        case E2eeAttachmentOriginalDownloadError.cipherSizeMismatch,
             E2eeAttachmentOriginalDownloadError.plaintextSizeMismatch:
            return "size"
        case E2eeAttachmentOriginalDownloadError.insufficientStorage:
            return "storage"
        case E2eeAttachmentOriginalDownloadError.protectedDataUnavailable:
            return "waiting_for_unlock"
        case E2eeAttachmentStagingError.noSpace(_):
            return "storage"
        case is CancellationError:
            return "canceled"
        default:
            return "download_or_decrypt"
        }
    }
}
