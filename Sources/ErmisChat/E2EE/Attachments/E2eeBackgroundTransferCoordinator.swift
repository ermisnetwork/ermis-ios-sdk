//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum E2eeBackgroundSessionEventHandlingResult: Equatable, Sendable {
    case accepted
    case unsupportedSessionIdentifier
    case completionHandlerAlreadyOwned
}

enum E2eeBackgroundTransferCoordinatorError: Error, Equatable {
    case invalidUploadRequest
    case invalidDownloadRequest
    case backgroundDownloadFailedRetryable
    case backgroundDownloadFailedTerminal
    case verifiedCiphertextUnavailable
    case sourceFileUnavailable
    case nonCanonicalUploadSource
    case attemptNotFound
    case assetNotFound
    case assetAlreadyScheduled
    case multipartPartNotFound
    case multipartPartAlreadyScheduled
    case multipartConcurrencyLimit
    case invalidMultipartPartFile
    case multipartStateChanged
    case appExtensionCannotSchedule
}

struct E2eeVerifiedBackgroundCiphertextLease: @unchecked Sendable {
    let localURL: URL
    let downloadId: String
    private let consumeHandler: @Sendable () async -> Void

    init(
        localURL: URL,
        downloadId: String,
        consumeHandler: @escaping @Sendable () async -> Void
    ) {
        self.localURL = localURL
        self.downloadId = downloadId
        self.consumeHandler = consumeHandler
    }

    /// Deletes verified ciphertext only after authenticated plaintext has been persisted.
    func consume() async {
        await consumeHandler()
    }
}

struct E2eeBackgroundSessionDescriptor: Equatable, Sendable {
    let identifier: String
    let storageNamespace: String

    init(
        bundleIdentifier: String,
        endpoint: URL,
        applicationGroupIdentifier: String?
    ) {
        let safeBundle = bundleIdentifier
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "." || character == "-"
                    ? character
                    : "-"
            }
        let environment = [
            endpoint.scheme?.lowercased() ?? "",
            endpoint.host?.lowercased() ?? "",
            endpoint.port.map(String.init) ?? "",
            endpoint.path,
            applicationGroupIdentifier ?? ""
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(environment.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        storageNamespace = digest
        identifier = "network.ermis.e2ee.transfer.\(String(safeBundle.prefix(100))).\(digest)"
    }
}

/// Owns one background session per app/environment. URLSession delegates only append opaque
/// events; protected pending records are hydrated and mutated by reconciliation afterwards.
final class E2eeBackgroundTransferCoordinator: NSObject {
    typealias SessionConfigurationBuilder = (String, String?) -> URLSessionConfiguration

    let sessionIdentifier: String

    /// Internal access is intentionally limited to the attachment preparation orchestrator. It
    /// must use the exact same durable store instance as callback reconciliation.
    let store: E2eeDurableTransferStore
    let stagingStore: E2eeAttachmentStagingStore
    let backgroundDownloadStore: E2eeDurableBackgroundDownloadStore
    private let multipartPartFileStore: E2eeMultipartPartFileStore
    private let journal: BackgroundTransferEventJournal
    private let drainer: E2eeBackgroundTransferEventDrainer
    private let backgroundDownloadFileStore: E2eeBackgroundDownloadFileStore
    private let backgroundDownloadDrainer: E2eeBackgroundDownloadEventDrainer
    private let stateQueue = DispatchQueue(label: "network.ermis.e2ee.background-transfer-state")
    private let delegateQueue: OperationQueue
    private var session: URLSession!
    private var hostCompletionHandler: (() -> Void)?
    private var didFinishBackgroundEvents = false
    private var undurableDelegateEvents: [BackgroundTransferEvent] = []
    private var protectedDataObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var reconcilePassGate = E2eeReconcilePassGate()
    private var pendingReconcileCompletions: [(Result<Void, Error>) -> Void] = []
    private var transferObservers: [UUID: (PendingE2eeTransferAttempt) -> Void] = [:]
    private var attachmentFinalizer: E2eeAttachmentFinalizer?
    private var progressJournalThrottle = E2eeTransferProgressJournalThrottle()
    private var bodySentReconcileGate = E2eeBodySentReconcileGate()
    /// `didFinishDownloadingTo` must move the temporary file before returning. If that synchronous
    /// capture fails, remember the opaque token until `didCompleteWithError` writes the durable
    /// terminal callback. This set is delegate-queue confined.
    private var downloadCaptureFailedTokens = Set<String>()
    /// A missing single PUT is retried at most once per asset/process with the same presigned URL
    /// and byte-identical canonical ciphertext. This repairs a lost URLSession task without ever
    /// minting a new attachment ID, CEK, nonce, or message intent.
    private var recoveredMissingSinglePutAssetKeys = Set<String>()

    init(
        descriptor: E2eeBackgroundSessionDescriptor,
        rootURL: URL,
        applicationGroupIdentifier: String?,
        sessionConfigurationBuilder: @escaping SessionConfigurationBuilder = E2eeBackgroundTransferCoordinator.makeSessionConfiguration
    ) {
        sessionIdentifier = descriptor.identifier
        let scopedRootURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(descriptor.storageNamespace, isDirectory: true)
        store = E2eeDurableTransferStore(rootURL: scopedRootURL)
        let backgroundDownloadStore = E2eeDurableBackgroundDownloadStore(rootURL: scopedRootURL)
        self.backgroundDownloadStore = backgroundDownloadStore
        let backgroundDownloadFileStore = E2eeBackgroundDownloadFileStore(rootURL: scopedRootURL)
        self.backgroundDownloadFileStore = backgroundDownloadFileStore
        let stagingStore = E2eeAttachmentStagingStore(rootURL: scopedRootURL)
        self.stagingStore = stagingStore
        multipartPartFileStore = E2eeMultipartPartFileStore(stagingStore: stagingStore)
        let journal = BackgroundTransferEventJournal(
            url: rootURL.deletingLastPathComponent()
                .appendingPathComponent("E2EEAttachmentTransferCallbacks", isDirectory: true)
                .appendingPathComponent("\(descriptor.storageNamespace).journal")
        )
        self.journal = journal
        drainer = E2eeBackgroundTransferEventDrainer(store: store, journal: journal)
        backgroundDownloadDrainer = E2eeBackgroundDownloadEventDrainer(
            store: backgroundDownloadStore,
            fileStore: backgroundDownloadFileStore,
            journal: journal
        )
        let delegateQueue = OperationQueue()
        delegateQueue.name = "network.ermis.e2ee.background-transfer-delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue
        super.init()
        session = URLSession(
            configuration: sessionConfigurationBuilder(
                descriptor.identifier,
                applicationGroupIdentifier
            ),
            delegate: self,
            delegateQueue: delegateQueue
        )
        observeProtectedDataAvailability()
        observeForegroundActivation()
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.retryUndurableDelegateEventsLocked()
            self.publishTransferSnapshotsLocked()
        }
        resumeMultipartUploads { _ in }
    }

    /// Observes durable transfer snapshots. The initial hydrated state is replayed so a worker
    /// created after app relaunch cannot miss a callback that arrived earlier in launch.
    @discardableResult
    func addTransferObserver(
        _ observer: @escaping (PendingE2eeTransferAttempt) -> Void
    ) -> UUID {
        let id = UUID()
        stateQueue.sync {
            self.transferObservers[id] = observer
            guard let attempts = try? self.store.hydrate() else { return }
            attempts.forEach(observer)
        }
        return id
    }

    func removeTransferObserver(_ id: UUID) {
        stateQueue.async { [weak self] in
            self?.transferObservers.removeValue(forKey: id)
        }
    }

    /// Returns whether the logical message already owns a durable transfer attempt. The upload
    /// worker uses this during relaunch rescue so Core Data's generic `uploading -> pendingUpload`
    /// reset cannot create a second attachment init/ciphertext generation for the same message.
    func hasDurableAttempt(messageId: String, accountId: String) -> Bool {
        stateQueue.sync {
            (try? store.hydrate().contains {
                $0.messageId == messageId && $0.accountId == accountId
            }) == true
        }
    }

    /// Replays durable state before reconciling URLSession. This is intentionally callable after
    /// authentication because the initial snapshot replay can occur before `currentUserId` is
    /// available to the attachment worker.
    func replayAndResumeDurableTransfers() {
        stateQueue.async { [weak self] in
            self?.publishTransferSnapshotsLocked()
        }
        resumeMultipartUploads { result in
            if case let .failure(error) = result {
                log.error(
                    "[E2EE_ATTACHMENT] stage=relaunch_resume state=failed error=\(e2eeTransferDiagnostic(error))",
                    subsystems: .mls
                )
            }
        }
    }

    /// Preparation/finalization mutate the same durable store outside `stateQueue`. They call
    /// this after a durable write so observers always receive state that can survive relaunch.
    func notifyTransferStoreChanged() {
        stateQueue.async { [weak self] in
            self?.publishTransferSnapshotsLocked()
        }
    }

    /// Persists the protected logical mapping before starting the shared background session task.
    /// Only opaque task metadata is exposed to URLSession callbacks and the unprotected journal.
    @discardableResult
    func scheduleBackgroundDownload(
        accountId: String,
        cid: String,
        attachmentId: String,
        assetId: String,
        request: URLRequest,
        expectedCiphertextSize: Int64,
        expectedCiphertextSha256: String
    ) throws -> E2eeDurableBackgroundDownload {
        guard !Bundle.main.isAppExtension else {
            throw E2eeBackgroundTransferCoordinatorError.appExtensionCannotSchedule
        }
        guard request.url != nil,
              request.httpMethod?.uppercased() == "GET",
              expectedCiphertextSize > 0 else {
            throw E2eeBackgroundTransferCoordinatorError.invalidDownloadRequest
        }

        let taskToken = UUID().uuidString
        let task = session.downloadTask(with: request)
        task.taskDescription = taskToken
        let record = E2eeDurableBackgroundDownload(
            accountId: accountId,
            cid: cid,
            attachmentId: attachmentId,
            assetId: assetId,
            taskToken: taskToken,
            taskIdentifier: task.taskIdentifier,
            expectedCiphertextSize: expectedCiphertextSize,
            expectedCiphertextSha256: expectedCiphertextSha256
        )
        do {
            let result = try backgroundDownloadStore.insertOrExisting(record)
            guard result.inserted else {
                task.cancel()
                return result.record
            }
        } catch {
            task.cancel()
            throw error
        }
        task.resume()
        log.info(
            "[E2EE_ATTACHMENT_GET] transport=background state=scheduled expected_bytes=\(expectedCiphertextSize)",
            subsystems: .mls
        )
        return record
    }

    /// Returns globally verified ciphertext for one logical original. Closing a viewer only
    /// cancels this polling waiter; it never cancels the SDK-owned background URLSession task.
    /// A retryable terminal attempt receives one fresh grant/GET while preserving logical IDs.
    func acquireVerifiedBackgroundCiphertext(
        accountId: String,
        cid: String,
        attachmentId: String,
        assetId: String,
        expectedCiphertextSize: Int64,
        expectedCiphertextSha256: String,
        requestProvider: @escaping @Sendable () async throws -> URLRequest,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> E2eeVerifiedBackgroundCiphertextLease {
        var retryCount = 0

        // A canceled record is a durable tombstone for waiters that were already polling when
        // the user pressed Cancel. A later explicit open is a new user intent, so retire old
        // tombstones before scheduling a fresh grant/GET.
        try? backgroundDownloadDrainer.drain()
        for canceled in try backgroundDownloadStore.records(
            accountId: accountId,
            cid: cid,
            attachmentId: attachmentId,
            assetId: assetId
        ) where canceled.phase == .canceled {
            try removeBackgroundDownload(canceled)
        }

        while true {
            try Task.checkCancellation()
            try? backgroundDownloadDrainer.drain()

            let current = try backgroundDownloadStore.newestRecord(
                accountId: accountId,
                cid: cid,
                attachmentId: attachmentId,
                assetId: assetId,
                expectedCiphertextSize: expectedCiphertextSize,
                expectedCiphertextSha256: expectedCiphertextSha256
            )

            if let current {
                progress(current.completedCiphertextBytes, current.expectedCiphertextSize)
                switch current.phase {
                case .waitingForUnlock:
                    guard let localURL = current.verifiedCiphertextURL,
                          backgroundDownloadFileStore.verifiedFileURL(
                              downloadId: current.downloadId
                          ) == localURL else {
                        try removeBackgroundDownload(current)
                        if retryCount >= 1 {
                            throw E2eeBackgroundTransferCoordinatorError.verifiedCiphertextUnavailable
                        }
                        retryCount += 1
                        continue
                    }
                    return E2eeVerifiedBackgroundCiphertextLease(
                        localURL: localURL,
                        downloadId: current.downloadId
                    ) { [weak self] in
                        self?.consumeBackgroundDownload(downloadId: current.downloadId)
                    }

                case .scheduled, .downloading:
                    break

                case .failedRetryable:
                    try removeBackgroundDownload(current)
                    guard retryCount < 1 else {
                        throw E2eeBackgroundTransferCoordinatorError.backgroundDownloadFailedRetryable
                    }
                    retryCount += 1
                    continue

                case .failedTerminal:
                    throw E2eeBackgroundTransferCoordinatorError.backgroundDownloadFailedTerminal

                case .canceled:
                    throw CancellationError()

                case .completed:
                    try removeBackgroundDownload(current)
                    continue
                }
            } else {
                let request = try await requestProvider()
                try Task.checkCancellation()
                _ = try scheduleBackgroundDownload(
                    accountId: accountId,
                    cid: cid,
                    attachmentId: attachmentId,
                    assetId: assetId,
                    request: request,
                    expectedCiphertextSize: expectedCiphertextSize,
                    expectedCiphertextSha256: expectedCiphertextSha256
                )
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func consumeBackgroundDownload(downloadId: String) {
        guard let record = try? backgroundDownloadStore.record(downloadId: downloadId) else {
            return
        }
        backgroundDownloadFileStore.removeFiles(for: record)
        try? backgroundDownloadStore.remove(downloadId: downloadId)
        log.info(
            "[E2EE_ATTACHMENT_GET] transport=background state=consumed",
            subsystems: .mls
        )
    }

    private func removeBackgroundDownload(_ record: E2eeDurableBackgroundDownload) throws {
        backgroundDownloadFileStore.removeFiles(for: record)
        try backgroundDownloadStore.remove(downloadId: record.downloadId)
    }

    /// Cancels only the exact receive-side original selected by the user.
    ///
    /// The durable canceled tombstone remains long enough to stop existing polling waiters from
    /// recreating the GET. A later explicit open retires that tombstone and starts a fresh grant.
    func cancelBackgroundDownload(
        accountId: String,
        cid: String,
        attachmentId: String,
        assetId: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let downloads = try self.backgroundDownloadStore.records(
                    accountId: accountId,
                    cid: cid,
                    attachmentId: attachmentId,
                    assetId: assetId
                )
                let tokens = Set(downloads.map(\.taskToken))
                self.session.getAllTasks { [weak self] tasks in
                    guard let self else { return }
                    self.stateQueue.async {
                        tasks.filter { task in
                            task.taskDescription.map(tokens.contains) == true
                        }.forEach { $0.cancel() }

                        do {
                            for download in downloads {
                                self.backgroundDownloadFileStore.removeFiles(for: download)
                                _ = try self.backgroundDownloadStore.update(
                                    downloadId: download.downloadId
                                ) { record in
                                    record.phase = .canceled
                                    record.fixedError = .canceled
                                    record.verifiedCiphertextURL = nil
                                }
                            }
                            log.info(
                                "[E2EE_ATTACHMENT_GET] transport=background state=canceled_exact",
                                subsystems: .mls
                            )
                            completion(.success(()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    func configureCompletionClient(
        _ client: E2eeAttachmentCompletionClient,
        messageBinding: E2eeAttachmentMessageBinding
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let finalizer = E2eeAttachmentFinalizer(
                store: self.store,
                stagingStore: self.stagingStore,
                client: client,
                manifestBuilder: E2eeAttachmentManifestBuilder(
                    wrappingKeyStore: E2eeAttachmentWrappingKeyStore(access: .mainApp)
                ),
                messageBinding: messageBinding,
                stateDidChange: { [weak self] in
                    self?.notifyTransferStoreChanged()
                }
            )
            self.attachmentFinalizer = finalizer
            // Completion callbacks can beat client wiring during launch. Re-scan durable ready
            // attempts as soon as the finalizer becomes available instead of waiting for another
            // foreground/relaunch reconciliation.
            Task { await finalizer.finalizeReadyAttempts() }
        }
    }

    @discardableResult
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> E2eeBackgroundSessionEventHandlingResult {
        guard identifier == sessionIdentifier else {
            return .unsupportedSessionIdentifier
        }
        return stateQueue.sync {
            guard hostCompletionHandler == nil else {
                return .completionHandlerAlreadyOwned
            }
            hostCompletionHandler = completionHandler
            finishHostBackgroundEventsIfPossibleLocked()
            return .accepted
        }
    }

    /// Schedules only canonical ciphertext files. The opaque token/task mapping is durable before
    /// `resume`, so a callback can always be matched after process death.
    @discardableResult
    func scheduleSinglePut(
        attemptId: String,
        assetId: String,
        request: URLRequest,
        fileURL: URL
    ) throws -> Int {
        guard !Bundle.main.isAppExtension else {
            throw E2eeBackgroundTransferCoordinatorError.appExtensionCannotSchedule
        }
        guard request.url != nil, request.httpMethod?.uppercased() == "PUT" else {
            throw E2eeBackgroundTransferCoordinatorError.invalidUploadRequest
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw E2eeBackgroundTransferCoordinatorError.sourceFileUnavailable
        }
        try stagingStore.prepareEncryptedDirectories()
        guard stagingStore.isCanonicalCiphertext(fileURL) else {
            throw E2eeBackgroundTransferCoordinatorError.nonCanonicalUploadSource
        }

        let taskToken = UUID().uuidString
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = taskToken
        do {
            _ = try store.update(attemptId: attemptId) { attempt in
                guard let assetIndex = attempt.assets.firstIndex(where: { $0.assetId == assetId }) else {
                    throw E2eeBackgroundTransferCoordinatorError.assetNotFound
                }
                guard attempt.assets[assetIndex].taskIdentifier == nil,
                      attempt.assets[assetIndex].taskToken == nil,
                      !attempt.assets[assetIndex].isUploaded else {
                    throw E2eeBackgroundTransferCoordinatorError.assetAlreadyScheduled
                }
                attempt.assets[assetIndex].uploadMode = .singlePut
                attempt.assets[assetIndex].taskIdentifier = task.taskIdentifier
                attempt.assets[assetIndex].taskToken = taskToken
                attempt.phase = .uploading
                attempt.failureReason = nil
                if attempt.totalBytes == 0 {
                    let total = attempt.assets.compactMap(\.ciphertextSize).reduce(UInt64(0), +)
                    attempt.totalBytes = Int64(clamping: total)
                }
            }
        } catch {
            task.cancel()
            throw error
        }
        task.resume()
        notifyTransferStoreChanged()
        log.info(
            "[E2EE_ATTACHMENT_PUT] transport=single state=scheduled bytes=\(Self.fileSize(fileURL) ?? 0)",
            subsystems: .mls
        )
        return task.taskIdentifier
    }

    /// Schedules an already-materialized multipart part. At most the clamped foreground window is
    /// active; the extra `+1` file is a prefetched disk file, not another URLSession task.
    @discardableResult
    func scheduleMultipartPart(
        attemptId: String,
        assetId: String,
        partNumber: Int,
        request: URLRequest,
        fileURL: URL,
        concurrency: Int = E2eeMultipartPartFileStore.defaultConcurrency
    ) throws -> Int {
        guard !Bundle.main.isAppExtension else {
            throw E2eeBackgroundTransferCoordinatorError.appExtensionCannotSchedule
        }
        guard request.httpMethod?.uppercased() == "PUT", let requestURL = request.url else {
            throw E2eeBackgroundTransferCoordinatorError.invalidUploadRequest
        }
        guard stagingStore.isMultipartPart(fileURL),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw E2eeBackgroundTransferCoordinatorError.invalidMultipartPartFile
        }

        let attempt = try store.attempt(attemptId: attemptId)
        guard let asset = attempt.assets.first(where: { $0.assetId == assetId }),
              asset.uploadMode == .multipart else {
            throw E2eeBackgroundTransferCoordinatorError.assetNotFound
        }
        guard let part = asset.parts.first(where: { $0.number == partNumber }) else {
            throw E2eeBackgroundTransferCoordinatorError.multipartPartNotFound
        }
        guard part.eTag == nil, part.taskIdentifier == nil, part.taskToken == nil else {
            throw E2eeBackgroundTransferCoordinatorError.multipartPartAlreadyScheduled
        }
        guard part.putURL == requestURL,
              part.localFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
              Self.fileSize(fileURL) == part.size else {
            throw E2eeBackgroundTransferCoordinatorError.invalidMultipartPartFile
        }
        let maximumActive = E2eeMultipartPartFileStore.clampedConcurrency(concurrency)
        let activeCount = asset.parts.filter { $0.taskToken != nil }.count
        guard activeCount < maximumActive else {
            throw E2eeBackgroundTransferCoordinatorError.multipartConcurrencyLimit
        }

        let taskToken = UUID().uuidString
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = taskToken
        do {
            _ = try store.update(attemptId: attemptId) { record in
                guard let assetIndex = record.assets.firstIndex(where: { $0.assetId == assetId }),
                      let partIndex = record.assets[assetIndex].parts.firstIndex(where: { $0.number == partNumber }) else {
                    throw E2eeBackgroundTransferCoordinatorError.multipartPartNotFound
                }
                guard record.assets[assetIndex].parts[partIndex].eTag == nil,
                      record.assets[assetIndex].parts[partIndex].taskIdentifier == nil,
                      record.assets[assetIndex].parts[partIndex].taskToken == nil else {
                    throw E2eeBackgroundTransferCoordinatorError.multipartPartAlreadyScheduled
                }
                record.assets[assetIndex].parts[partIndex].taskIdentifier = task.taskIdentifier
                record.assets[assetIndex].parts[partIndex].taskToken = taskToken
                record.phase = .uploading
                record.failureReason = nil
                if record.totalBytes == 0 {
                    record.totalBytes = Int64(clamping: Self.totalCiphertextBytes(record))
                }
            }
        } catch {
            task.cancel()
            throw error
        }
        task.resume()
        notifyTransferStoreChanged()
        log.info(
            "[E2EE_ATTACHMENT_PUT] transport=multipart state=part_scheduled part_number=\(partNumber) part_count=\(asset.parts.count) bytes=\(part.size) active_count=\(activeCount + 1)",
            subsystems: .mls
        )
        return task.taskIdentifier
    }

    @discardableResult
    func materializeMultipartWindow(
        attemptId: String,
        assetId: String,
        concurrency: Int = E2eeMultipartPartFileStore.defaultConcurrency
    ) throws -> [PendingE2eeMultipartPart] {
        let attempt = try store.attempt(attemptId: attemptId)
        guard let asset = attempt.assets.first(where: { $0.assetId == assetId }),
              asset.uploadMode == .multipart,
              let canonicalURL = asset.canonicalCiphertextURL else {
            throw E2eeBackgroundTransferCoordinatorError.assetNotFound
        }
        let result = try multipartPartFileStore.materializeWindow(
            attemptId: attemptId,
            assetId: assetId,
            canonicalCiphertextURL: canonicalURL,
            parts: asset.parts,
            concurrency: concurrency
        )
        let updated = try store.update(attemptId: attemptId) { record in
            guard let assetIndex = record.assets.firstIndex(where: { $0.assetId == assetId }),
                  record.assets[assetIndex].parts == asset.parts else {
                throw E2eeBackgroundTransferCoordinatorError.multipartStateChanged
            }
            record.assets[assetIndex].parts = result.parts
            record.phase = .uploading
            record.failureReason = nil
        }
        notifyTransferStoreChanged()
        return updated.assets.first(where: { $0.assetId == assetId })?.parts ?? []
    }

    func reconcile(completion: @escaping (Result<Void, Error>) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.pendingReconcileCompletions.append(completion)
            guard self.reconcilePassGate.requestPass() else { return }
            self.runReconcilePassLocked()
        }
    }

    /// A completion callback can be appended while an earlier reconciliation pass is between
    /// journal drain and `getAllTasks`. Coalescing that callback into the in-flight pass would
    /// leave its completion event undrained, with transport progress at 100% but the asset not
    /// marked uploaded. The gate therefore guarantees one additional full pass whenever a
    /// request arrives during an active pass.
    private func runReconcilePassLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        do {
            _ = try drainer.drain()
            _ = try backgroundDownloadDrainer.drain()
        } catch {
            log.error(
                "[E2EE_ATTACHMENT] stage=reconcile_journal_drain state=failed error=\(e2eeTransferDiagnostic(error))",
                subsystems: .mls
            )
            finishReconcilePassLocked(.failure(error))
            return
        }
        do {
            try cleanupUploadedMultipartPartFiles()
            let attempts = try store.hydrate()
            try markReconciling(attempts)
        } catch {
            log.error(
                "[E2EE_ATTACHMENT] stage=reconcile_prepare state=failed error=\(e2eeTransferDiagnostic(error))",
                subsystems: .mls
            )
            finishReconcilePassLocked(.failure(error))
            return
        }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.stateQueue.async {
                do {
                    try self.applyReconciliation(osTasks: tasks)
                    self.publishTransferSnapshotsLocked()
                    self.finishReconcilePassLocked(.success(()))
                } catch {
                    log.error(
                        "[E2EE_ATTACHMENT] stage=reconcile_apply state=failed error=\(e2eeTransferDiagnostic(error))",
                        subsystems: .mls
                    )
                    self.finishReconcilePassLocked(.failure(error))
                }
            }
        }
    }

    private func finishReconcilePassLocked(_ result: Result<Void, Error>) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if reconcilePassGate.finishPassAndShouldRunAgain() {
            log.debug(
                "[E2EE_ATTACHMENT] stage=reconcile state=trailing_pass_started",
                subsystems: .mls
            )
            runReconcilePassLocked()
            return
        }
        finishReconcileLocked(result)
    }

    func resumeMultipartUploads(
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        reconcile { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                completion(result)
                return
            }
            do {
                try self.scheduleNextMultipartWindowsLocked()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancelTasks(accountId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let attempts = try self.store.hydrate().filter { $0.accountId == accountId }
                let downloads = try self.backgroundDownloadStore.records(accountId: accountId)
                let tokens = Set(attempts.flatMap(Self.taskTokens) + downloads.map(\.taskToken))
                self.session.getAllTasks { [weak self] tasks in
                    guard let self else { return }
                    self.stateQueue.async {
                        tasks.filter { task in
                            task.taskDescription.map(tokens.contains) == true
                        }.forEach { $0.cancel() }
                        do {
                            for attempt in attempts where attempt.phase != .canceled && attempt.phase != .confirmed {
                                // URLSession cancellation is issued before any SDK-owned upload
                                // source is removed. Late callbacks become stale after task-token
                                // mappings are cleared and cannot revive the canceled attempt.
                                try self.cleanupCanceledAttemptFiles(attempt)
                                _ = try self.store.update(attemptId: attempt.attemptId) { record in
                                    record.phase = .canceled
                                    record.failureReason = nil
                                    for assetIndex in record.assets.indices {
                                        record.assets[assetIndex].canonicalCiphertextURL = nil
                                        record.assets[assetIndex].taskIdentifier = nil
                                        record.assets[assetIndex].taskToken = nil
                                        for partIndex in record.assets[assetIndex].parts.indices {
                                            record.assets[assetIndex].parts[partIndex].localFileURL = nil
                                            record.assets[assetIndex].parts[partIndex].taskIdentifier = nil
                                            record.assets[assetIndex].parts[partIndex].taskToken = nil
                                        }
                                    }
                                }
                            }
                            for download in downloads {
                                self.backgroundDownloadFileStore.removeFiles(for: download)
                                try self.backgroundDownloadStore.remove(downloadId: download.downloadId)
                            }
                            self.publishTransferSnapshotsLocked()
                            completion(.success(()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Called only after Bellboy's authoritative message response has been persisted locally.
    /// The account guard keeps the shared background session isolated even if IDs collide.
    func confirmMessage(
        messageId: String,
        accountId: String,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let attempts = try self.store.hydrate().filter {
                    $0.messageId == messageId && $0.accountId == accountId
                }
                for attempt in attempts where attempt.phase == .sending {
                    _ = try self.store.update(attemptId: attempt.attemptId) { record in
                        record.phase = .confirmed
                        record.failureReason = nil
                    }
                }
                try self.cleanupConfirmedAttemptsIfNeeded(
                    attempts.filter { $0.phase == .sending || $0.phase == .confirmed }
                )
                self.publishTransferSnapshotsLocked()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func cleanupCanceledAttemptFiles(_ attempt: PendingE2eeTransferAttempt) throws {
        for asset in attempt.assets {
            if let sourceURL = asset.sourceURL {
                try stagingStore.removeSource(sourceURL)
            }
            if let canonicalURL = asset.canonicalCiphertextURL {
                try stagingStore.removeCanonicalCiphertext(canonicalURL)
            }
            try stagingStore.removeMultipartAssetDirectory(
                attemptId: attempt.attemptId,
                assetId: asset.assetId
            )
        }
    }

    private func markReconciling(_ attempts: [PendingE2eeTransferAttempt]) throws {
        for attempt in attempts where Self.canReconcile(attempt.phase) && Self.hasScheduledTask(attempt) {
            _ = try store.update(attemptId: attempt.attemptId) { record in
                // Finalization runs on its own actor and can advance the record after `hydrate`.
                // Re-check the current durable phase inside the atomic update so a stale snapshot
                // cannot regress `.finalizing`/`.sending` back to `.reconciling`.
                guard Self.canReconcile(record.phase), Self.hasScheduledTask(record) else { return }
                record.phase = .reconciling
                record.failureReason = nil
            }
        }
    }

    private func finishReconcileLocked(_ result: Result<Void, Error>) {
        let completions = pendingReconcileCompletions
        pendingReconcileCompletions.removeAll(keepingCapacity: true)
        completions.forEach { $0(result) }
    }

    private func publishTransferSnapshotsLocked() {
        guard !transferObservers.isEmpty,
              let attempts = try? store.hydrate() else { return }
        let observers = Array(transferObservers.values)
        for attempt in attempts {
            observers.forEach { $0(attempt) }
        }
    }

    private func scheduleNextMultipartWindowsLocked() throws {
        let attempts = try store.hydrate().filter {
            Self.canReconcile($0.phase) && $0.failureReason == nil
        }
        for attempt in attempts {
            for asset in attempt.assets where asset.uploadMode == .multipart {
                let limit = E2eeMultipartPartFileStore.defaultConcurrency
                let currentlyActive = asset.parts.filter { $0.taskToken != nil }.count
                guard currentlyActive < limit else { continue }
                let parts = try materializeMultipartWindow(
                    attemptId: attempt.attemptId,
                    assetId: asset.assetId
                )
                var activeCount = parts.filter { $0.taskToken != nil }.count
                for part in parts where activeCount < limit {
                    guard part.eTag == nil,
                          part.taskToken == nil,
                          let fileURL = part.localFileURL,
                          let putURL = part.putURL else { continue }
                    var request = URLRequest(url: putURL)
                    request.httpMethod = "PUT"
                    _ = try scheduleMultipartPart(
                        attemptId: attempt.attemptId,
                        assetId: asset.assetId,
                        partNumber: part.number,
                        request: request,
                        fileURL: fileURL
                    )
                    activeCount += 1
                }
            }
        }
    }

    private func applyReconciliation(osTasks: [URLSessionTask]) throws {
        _ = try drainer.drain()
        _ = try backgroundDownloadDrainer.drain()
        try cleanupUploadedMultipartPartFiles()
        try cleanupConfirmedAttemptsIfNeeded()
        try expireUploadAttemptsIfNeeded(osTasks: osTasks)
        var activeTokens = Set<String>()
        var activeDownloadTokens = Set<String>()
        for task in osTasks {
            guard let token = task.taskDescription, UUID(uuidString: token) != nil else {
                task.cancel()
                continue
            }
            if task is URLSessionDownloadTask {
                guard let record = try backgroundDownloadStore.record(taskToken: token),
                      record.taskIdentifier == task.taskIdentifier else {
                    task.cancel()
                    continue
                }
                activeDownloadTokens.insert(token)
            } else {
                guard let attempt = try store.attempt(taskToken: token),
                      Self.matches(taskIdentifier: task.taskIdentifier, token: token, attempt: attempt) else {
                    task.cancel()
                    continue
                }
                activeTokens.insert(token)
            }
        }

        var activeAttemptCount = 0
        var missingAttemptCount = 0
        var finalizingAttemptCount = 0
        for attempt in try store.hydrate() where Self.canReconcile(attempt.phase) {
            let scheduledTokens = Set(Self.taskTokens(attempt))
            let missingTask = !scheduledTokens.subtracting(activeTokens).isEmpty
            let activeTask = !scheduledTokens.intersection(activeTokens).isEmpty
            if missingTask {
                if try recoverMissingSinglePutTasksLocked(
                    attempt: attempt,
                    activeTokens: activeTokens
                ) {
                    activeAttemptCount += 1
                    continue
                }
                missingAttemptCount += 1
            } else if activeTask {
                activeAttemptCount += 1
            } else if Self.allTransportUploadsComplete(attempt) {
                finalizingAttemptCount += 1
            }
            _ = try store.update(attemptId: attempt.attemptId) { record in
                // The finalizer can advance this attempt while URLSession enumerates tasks.
                // Transport reconciliation must never overwrite a newer logical lifecycle phase.
                guard Self.canReconcile(record.phase) else { return }
                if missingTask {
                    record.phase = .failedRetryable
                    record.failureReason = .backgroundTaskMissing
                } else if activeTask {
                    record.phase = .waitingForSystem
                    record.failureReason = nil
                } else if Self.allTransportUploadsComplete(record) {
                    record.phase = .finalizing
                    record.failureReason = nil
                } else if record.phase == .reconciling {
                    record.phase = .uploading
                    record.failureReason = nil
                }
            }
        }
        log.info(
            "[E2EE_ATTACHMENT] stage=reconcile state=evaluated os_task_count=\(osTasks.count) active_attempt_count=\(activeAttemptCount) missing_attempt_count=\(missingAttemptCount) finalizing_attempt_count=\(finalizingAttemptCount)",
            subsystems: .mls
        )
        try reconcileBackgroundDownloads(activeTokens: activeDownloadTokens)
        triggerAttachmentFinalizationLocked()
    }

    private func reconcileBackgroundDownloads(activeTokens: Set<String>) throws {
        var activeCount = 0
        var missingCount = 0
        for record in try backgroundDownloadStore.hydrate() where !record.phase.isTerminal {
            if record.phase == .waitingForUnlock {
                continue
            }
            if activeTokens.contains(record.taskToken) {
                activeCount += 1
                _ = try backgroundDownloadStore.update(downloadId: record.downloadId) { updated in
                    updated.phase = .downloading
                    updated.fixedError = nil
                }
            } else {
                missingCount += 1
                _ = try backgroundDownloadStore.update(downloadId: record.downloadId) { updated in
                    updated.phase = .failedRetryable
                    updated.fixedError = .unknown
                }
            }
        }
        log.info(
            "[E2EE_ATTACHMENT_GET] stage=reconcile state=evaluated active_count=\(activeCount) missing_count=\(missingCount)",
            subsystems: .mls
        )
    }

    /// Replays a disappeared single PUT exactly once. PUT to the same opaque object key with the
    /// same canonical bytes is idempotent, while treating request-body progress as success is not.
    private func recoverMissingSinglePutTasksLocked(
        attempt: PendingE2eeTransferAttempt,
        activeTokens: Set<String>
    ) throws -> Bool {
        let missingTokens = Set(Self.taskTokens(attempt)).subtracting(activeTokens)
        let missingAssets = attempt.assets.filter { asset in
            asset.uploadMode == .singlePut
                && !asset.isUploaded
                && asset.taskToken.map { !activeTokens.contains($0) } == true
        }
        guard !missingAssets.isEmpty,
              Set(missingAssets.compactMap(\.taskToken)) == missingTokens else {
            return false
        }
        guard missingAssets.allSatisfy({ asset in
            let key = Self.missingSinglePutRecoveryKey(
                attemptId: attempt.attemptId,
                assetId: asset.assetId
            )
            return !recoveredMissingSinglePutAssetKeys.contains(key)
                && asset.uploadExpiresAt.map { $0 > Date() } == true
                && asset.putURL != nil
                && asset.canonicalCiphertextURL != nil
        }) else {
            return false
        }

        for asset in missingAssets {
            recoveredMissingSinglePutAssetKeys.insert(
                Self.missingSinglePutRecoveryKey(
                    attemptId: attempt.attemptId,
                    assetId: asset.assetId
                )
            )
        }
        _ = try store.update(attemptId: attempt.attemptId) { record in
            for missing in missingAssets {
                guard let index = record.assets.firstIndex(where: {
                    $0.assetId == missing.assetId
                }) else { continue }
                record.assets[index].taskIdentifier = nil
                record.assets[index].taskToken = nil
            }
            record.phase = .uploading
            record.failureReason = nil
        }

        do {
            for asset in missingAssets {
                guard let putURL = asset.putURL,
                      let canonicalURL = asset.canonicalCiphertextURL else {
                    throw E2eeBackgroundTransferCoordinatorError.sourceFileUnavailable
                }
                var request = URLRequest(url: putURL)
                request.httpMethod = "PUT"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                _ = try scheduleSinglePut(
                    attemptId: attempt.attemptId,
                    assetId: asset.assetId,
                    request: request,
                    fileURL: canonicalURL
                )
            }
            log.info(
                "[E2EE_ATTACHMENT_PUT] transport=single state=missing_task_replayed asset_count=\(missingAssets.count)",
                subsystems: .mls
            )
            return true
        } catch {
            _ = try? store.update(attemptId: attempt.attemptId) { record in
                record.phase = .failedRetryable
                record.failureReason = .backgroundTaskMissing
            }
            throw error
        }
    }

    private func triggerAttachmentFinalizationLocked() {
        guard let attachmentFinalizer else { return }
        Task { await attachmentFinalizer.finalizeReadyAttempts() }
    }

    private func expireUploadAttemptsIfNeeded(osTasks: [URLSessionTask]) throws {
        let now = Date()
        for attempt in try store.hydrate() where Self.canReconcile(attempt.phase) {
            guard attempt.assets.contains(where: { asset in
                asset.uploadExpiresAt.map { $0 <= now } == true
            }) else { continue }

            let tokens = Set(Self.taskTokens(attempt))
            osTasks.filter { task in
                task.taskDescription.map(tokens.contains) == true
            }.forEach { $0.cancel() }
            for asset in attempt.assets {
                try stagingStore.removeMultipartAssetDirectory(
                    attemptId: attempt.attemptId,
                    assetId: asset.assetId
                )
            }
            _ = try store.update(attemptId: attempt.attemptId) { record in
                record.phase = .failedRetryable
                record.failureReason = .uploadExpired
                for assetIndex in record.assets.indices {
                    record.assets[assetIndex].taskIdentifier = nil
                    record.assets[assetIndex].taskToken = nil
                    for partIndex in record.assets[assetIndex].parts.indices {
                        record.assets[assetIndex].parts[partIndex].localFileURL = nil
                        record.assets[assetIndex].parts[partIndex].taskIdentifier = nil
                        record.assets[assetIndex].parts[partIndex].taskToken = nil
                    }
                }
            }
        }
    }

    private func finishHostBackgroundEventsIfPossibleLocked() {
        retryUndurableDelegateEventsLocked()
        guard didFinishBackgroundEvents,
              hostCompletionHandler != nil,
              undurableDelegateEvents.isEmpty else { return }
        reconcile { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                guard case .success = result,
                      self.undurableDelegateEvents.isEmpty,
                      let completion = self.hostCompletionHandler else { return }
                self.hostCompletionHandler = nil
                self.didFinishBackgroundEvents = false
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    @discardableResult
    private func appendDelegateEvent(_ event: BackgroundTransferEvent) -> Bool {
        do {
            try journal.append(event)
            return true
        } catch {
            stateQueue.async { [weak self] in
                // Do not release the host completion handler: this callback has not become durable.
                self?.undurableDelegateEvents.append(event)
            }
            return false
        }
    }

    private func retryUndurableDelegateEventsLocked() {
        guard !undurableDelegateEvents.isEmpty else { return }
        var remaining: [BackgroundTransferEvent] = []
        for event in undurableDelegateEvents {
            do {
                try journal.append(event)
            } catch {
                remaining.append(event)
            }
        }
        undurableDelegateEvents = remaining
    }

    private func observeProtectedDataAvailability() {
#if canImport(UIKit)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stateQueue.async {
                guard let self else { return }
                self.retryUndurableDelegateEventsLocked()
                if self.didFinishBackgroundEvents {
                    self.finishHostBackgroundEventsIfPossibleLocked()
                } else {
                    self.resumeMultipartUploads { _ in }
                }
            }
        }
#endif
    }

    private func observeForegroundActivation() {
#if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resumeMultipartUploads { _ in }
        }
#endif
    }

    private static func makeSessionConfiguration(
        identifier: String,
        applicationGroupIdentifier: String?
    ) -> URLSessionConfiguration {
#if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.sharedContainerIdentifier = applicationGroupIdentifier
        return configuration
#else
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return configuration
#endif
    }

    private static func canReconcile(_ phase: E2eeTransferPhase) -> Bool {
        phase == .uploading || phase == .waitingForSystem || phase == .reconciling
    }

    private static func hasScheduledTask(_ attempt: PendingE2eeTransferAttempt) -> Bool {
        !taskTokens(attempt).isEmpty
    }

    private static func taskTokens(_ attempt: PendingE2eeTransferAttempt) -> [String] {
        attempt.assets.flatMap { asset in
            [asset.taskToken].compactMap { $0 } + asset.parts.compactMap(\.taskToken)
        }
    }

    private static func matches(
        taskIdentifier: Int,
        token: String,
        attempt: PendingE2eeTransferAttempt
    ) -> Bool {
        attempt.assets.contains { asset in
            (asset.taskToken == token && asset.taskIdentifier == taskIdentifier)
                || asset.parts.contains {
                    $0.taskToken == token && $0.taskIdentifier == taskIdentifier
                }
        }
    }

    private static func allTransportUploadsComplete(_ attempt: PendingE2eeTransferAttempt) -> Bool {
        !attempt.assets.isEmpty && attempt.assets.allSatisfy { asset in
            switch asset.uploadMode {
            case .singlePut:
                return asset.isUploaded
            case .multipart:
                return !asset.parts.isEmpty && asset.parts.allSatisfy(\.isUploaded)
            case nil:
                return false
            }
        }
    }

    private static func fixedError(_ error: Error?) -> BackgroundTransferFixedError {
        guard let error else { return .none }
        switch (error as? URLError)?.code {
        case .cancelled:
            return .canceled
        case .timedOut:
            return .timedOut
        case .networkConnectionLost:
            return .networkLost
        case .cannotConnectToHost, .cannotFindHost:
            return .cannotConnect
        case .notConnectedToInternet:
            return .notConnected
        default:
            return .unknown
        }
    }

    private func cleanupUploadedMultipartPartFiles() throws {
        for attempt in try store.hydrate() {
            for assetIndex in attempt.assets.indices where attempt.assets[assetIndex].uploadMode == .multipart {
                let previousParts = attempt.assets[assetIndex].parts
                let cleanedParts = try multipartPartFileStore.removeUploadedPartFiles(previousParts)
                guard cleanedParts != previousParts else { continue }
                _ = try store.update(attemptId: attempt.attemptId) { record in
                    guard let currentAssetIndex = record.assets.firstIndex(where: {
                        $0.assetId == attempt.assets[assetIndex].assetId
                    }) else { return }
                    record.assets[currentAssetIndex].parts = cleanedParts
                }
            }
        }
    }

    private func cleanupConfirmedAttemptsIfNeeded(
        _ candidates: [PendingE2eeTransferAttempt]? = nil
    ) throws {
        let attempts = try candidates ?? store.hydrate().filter { $0.phase == .confirmed }
        for attempt in attempts {
            let current = try store.attempt(attemptId: attempt.attemptId)
            guard current.phase == .confirmed else { continue }
            for asset in current.assets {
                if let sourceURL = asset.sourceURL {
                    try stagingStore.removeSource(sourceURL)
                }
                if let canonicalURL = asset.canonicalCiphertextURL {
                    try stagingStore.removeCanonicalCiphertext(canonicalURL)
                }
                try stagingStore.removeMultipartAssetDirectory(
                    attemptId: current.attemptId,
                    assetId: asset.assetId
                )
            }
            _ = try store.update(attemptId: current.attemptId) { record in
                for assetIndex in record.assets.indices {
                    record.assets[assetIndex].canonicalCiphertextURL = nil
                    record.assets[assetIndex].sourceURL = nil
                    record.assets[assetIndex].taskIdentifier = nil
                    record.assets[assetIndex].taskToken = nil
                    for partIndex in record.assets[assetIndex].parts.indices {
                        record.assets[assetIndex].parts[partIndex].localFileURL = nil
                        record.assets[assetIndex].parts[partIndex].taskIdentifier = nil
                        record.assets[assetIndex].parts[partIndex].taskToken = nil
                    }
                }
            }
        }
    }

    private static func totalCiphertextBytes(_ attempt: PendingE2eeTransferAttempt) -> UInt64 {
        attempt.assets.reduce(UInt64(0)) { total, asset in
            let (sum, overflow) = total.addingReportingOverflow(asset.ciphertextSize ?? 0)
            return overflow ? UInt64.max : sum
        }
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size >= 0 else { return nil }
        return UInt64(size)
    }

    private static func missingSinglePutRecoveryKey(
        attemptId: String,
        assetId: String
    ) -> String {
        attemptId + "\u{0}" + assetId
    }
}

extension E2eeBackgroundTransferCoordinator:
    URLSessionTaskDelegate,
    URLSessionDownloadDelegate,
    URLSessionDelegate
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let token = task.taskDescription, UUID(uuidString: token) != nil else {
            task.cancel()
            return
        }
        guard progressJournalThrottle.shouldPersist(
            taskToken: token,
            completedBytes: totalBytesSent,
            totalBytes: totalBytesExpectedToSend
        ) else { return }
        appendDelegateEvent(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: task.taskIdentifier,
                kind: .progress,
                completedBytes: max(0, totalBytesSent),
                totalBytes: max(0, totalBytesExpectedToSend),
                httpStatus: nil,
                eTag: nil,
                error: .none
            )
        )
        let percent = totalBytesExpectedToSend > 0
            ? min(100, Int((Double(totalBytesSent) / Double(totalBytesExpectedToSend)) * 100))
            : 0
        log.debug(
            "[E2EE_ATTACHMENT_PUT] transport=background state=progress percent=\(percent) bytes_sent=\(max(0, totalBytesSent)) total_bytes=\(max(0, totalBytesExpectedToSend))",
            subsystems: .mls
        )
        stateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let drained = try self.drainer.drain()
                if drained > 0 {
                    self.publishTransferSnapshotsLocked()
                }
            } catch {
                log.error(
                    "[E2EE_ATTACHMENT] transport=background state=progress_drain_failed error=\(type(of: error))",
                    subsystems: .mls
                )
            }
            if totalBytesExpectedToSend > 0,
               totalBytesSent >= totalBytesExpectedToSend,
               self.bodySentReconcileGate.schedule(taskToken: token) {
                log.info(
                    "[E2EE_ATTACHMENT_PUT] transport=background state=body_sent awaiting_http_completion=true",
                    subsystems: .mls
                )
                self.stateQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self,
                          self.bodySentReconcileGate.consume(taskToken: token) else { return }
                    log.info(
                        "[E2EE_ATTACHMENT_PUT] transport=background state=completion_watchdog_reconcile",
                        subsystems: .mls
                    )
                    self.resumeMultipartUploads { result in
                        if case .failure(let error) = result {
                            log.error(
                                "[E2EE_ATTACHMENT] stage=watchdog_reconcile state=failed error=\(e2eeTransferDiagnostic(error))",
                                subsystems: .mls
                            )
                        }
                    }
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let token = downloadTask.taskDescription, UUID(uuidString: token) != nil else {
            downloadTask.cancel()
            return
        }
        guard progressJournalThrottle.shouldPersist(
            taskToken: token,
            completedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        ) else { return }
        appendDelegateEvent(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: downloadTask.taskIdentifier,
                operation: .download,
                kind: .progress,
                completedBytes: max(0, totalBytesWritten),
                totalBytes: max(0, totalBytesExpectedToWrite),
                httpStatus: nil,
                eTag: nil,
                error: .none
            )
        )
        let percent = totalBytesExpectedToWrite > 0
            ? min(100, Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100))
            : 0
        log.debug(
            "[E2EE_ATTACHMENT_GET] transport=background state=progress percent=\(percent) bytes_received=\(max(0, totalBytesWritten)) total_bytes=\(max(0, totalBytesExpectedToWrite))",
            subsystems: .mls
        )
        stateQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.backgroundDownloadDrainer.drain()
            } catch {
                // Before first unlock, the protected mapping may not hydrate. The callback remains
                // in the unprotected journal and will be replayed after protected data is available.
                log.info(
                    "[E2EE_ATTACHMENT_GET] transport=background state=progress_drain_deferred error=\(type(of: error))",
                    subsystems: .mls
                )
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let token = downloadTask.taskDescription, UUID(uuidString: token) != nil else {
            downloadTask.cancel()
            return
        }
        do {
            _ = try backgroundDownloadFileStore.captureTemporaryFile(
                at: location,
                taskToken: token,
                taskIdentifier: downloadTask.taskIdentifier
            )
            log.info(
                "[E2EE_ATTACHMENT_GET] transport=background state=ciphertext_captured bytes_received=\(max(0, downloadTask.countOfBytesReceived))",
                subsystems: .mls
            )
        } catch {
            downloadCaptureFailedTokens.insert(token)
            log.error(
                "[E2EE_ATTACHMENT_GET] transport=background state=ciphertext_capture_failed error=\(type(of: error))",
                subsystems: .mls
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let token = task.taskDescription, UUID(uuidString: token) != nil else { return }
        let isDownload = task is URLSessionDownloadTask
        progressJournalThrottle.remove(taskToken: token)
        if !isDownload {
            stateQueue.async { [weak self] in
                self?.bodySentReconcileGate.cancel(taskToken: token)
            }
        }
        let response = task.response as? HTTPURLResponse
        let callbackError: BackgroundTransferFixedError
        if isDownload, downloadCaptureFailedTokens.remove(token) != nil, error == nil {
            callbackError = .unknown
        } else {
            callbackError = Self.fixedError(error)
        }
        let completedBytes = isDownload ? task.countOfBytesReceived : task.countOfBytesSent
        let totalBytes = isDownload
            ? task.countOfBytesExpectedToReceive
            : task.countOfBytesExpectedToSend
        let becameDurable = appendDelegateEvent(
            BackgroundTransferEvent(
                taskToken: token,
                taskIdentifier: task.taskIdentifier,
                operation: isDownload ? .download : .upload,
                kind: .completion,
                completedBytes: max(0, completedBytes),
                totalBytes: max(0, totalBytes),
                httpStatus: response?.statusCode,
                eTag: response?.value(forHTTPHeaderField: "ETag"),
                error: callbackError
            )
        )
        if isDownload {
            log.info(
                "[E2EE_ATTACHMENT_GET] transport=background state=completed http_status=\(response?.statusCode ?? 0) error=\(callbackError.rawValue) bytes_received=\(max(0, completedBytes)) total_bytes=\(max(0, totalBytes))",
                subsystems: .mls
            )
        } else {
            log.info(
                "[E2EE_ATTACHMENT_PUT] transport=background state=completed http_status=\(response?.statusCode ?? 0) error=\(callbackError.rawValue) bytes_sent=\(max(0, completedBytes)) total_bytes=\(max(0, totalBytes))",
                subsystems: .mls
            )
        }
        if becameDurable {
            if isDownload {
                reconcile { result in
                    if case .failure(let error) = result {
                        log.error(
                            "[E2EE_ATTACHMENT_GET] stage=completion_reconcile state=failed error=\(e2eeTransferDiagnostic(error))",
                            subsystems: .mls
                        )
                    }
                }
            } else {
                resumeMultipartUploads { result in
                    if case .failure(let error) = result {
                        log.error(
                            "[E2EE_ATTACHMENT] stage=completion_reconcile state=failed error=\(e2eeTransferDiagnostic(error))",
                            subsystems: .mls
                        )
                    }
                }
            }
        } else {
            log.error(
                "[E2EE_ATTACHMENT] stage=completion_journal state=not_durable",
                subsystems: .mls
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.didFinishBackgroundEvents = true
            self.finishHostBackgroundEventsIfPossibleLocked()
        }
    }
}

/// Progress is diagnostic/UI state, not a correctness boundary. Persisting every URLSession byte
/// callback would fsync the journal, rewrite the attempt record, and touch Core Data hundreds of
/// times for a video. Checkpoint at roughly five-percent increments; completion remains separately
/// and unconditionally journaled.
struct E2eeTransferProgressJournalThrottle {
    private var lastCompletedBytesByTaskToken: [String: Int64] = [:]

    mutating func shouldPersist(
        taskToken: String,
        completedBytes: Int64,
        totalBytes: Int64
    ) -> Bool {
        let completed = max(0, completedBytes)
        guard completed > 0 else { return false }
        let last = lastCompletedBytesByTaskToken[taskToken] ?? 0
        guard completed >= last else { return false }
        let checkpointSize = totalBytes > 0 ? max(Int64(1), totalBytes / 20) : 1024 * 1024
        guard completed == totalBytes || completed - last >= checkpointSize else { return false }
        lastCompletedBytesByTaskToken[taskToken] = completed
        return true
    }

    mutating func remove(taskToken: String) {
        lastCompletedBytesByTaskToken.removeValue(forKey: taskToken)
    }
}

/// Schedules one delayed reconciliation after URLSession reports that all request-body bytes were
/// sent. This never treats byte progress as upload success; it only re-checks the durable callback
/// journal and URLSession's authoritative task list if the HTTP completion callback is delayed.
struct E2eeBodySentReconcileGate {
    private var scheduledTaskTokens = Set<String>()

    mutating func schedule(taskToken: String) -> Bool {
        scheduledTaskTokens.insert(taskToken).inserted
    }

    mutating func cancel(taskToken: String) {
        scheduledTaskTokens.remove(taskToken)
    }

    mutating func consume(taskToken: String) -> Bool {
        scheduledTaskTokens.remove(taskToken) != nil
    }
}

/// Serial reconciliation request coalescing with a mandatory trailing pass. This small state
/// machine is deliberately independent from URLSession so the callback race is unit-testable.
struct E2eeReconcilePassGate {
    private(set) var isRunning = false
    private var trailingPassRequested = false

    mutating func requestPass() -> Bool {
        guard !isRunning else {
            trailingPassRequested = true
            return false
        }
        isRunning = true
        return true
    }

    /// Returns `true` while retaining the running lease for the mandatory trailing pass.
    mutating func finishPassAndShouldRunAgain() -> Bool {
        guard trailingPassRequested else {
            isRunning = false
            return false
        }
        trailingPassRequested = false
        return true
    }
}

private final class WeakBackgroundTransferCoordinator {
    weak var value: E2eeBackgroundTransferCoordinator?

    init(_ value: E2eeBackgroundTransferCoordinator) {
        self.value = value
    }
}

enum E2eeBackgroundTransferCoordinatorRegistry {
    private static let lock = NSLock()
    private static var coordinators: [String: WeakBackgroundTransferCoordinator] = [:]

    static func coordinator(
        descriptor: E2eeBackgroundSessionDescriptor,
        rootURL: URL,
        applicationGroupIdentifier: String?
    ) -> E2eeBackgroundTransferCoordinator {
        lock.withLock {
            if let existing = coordinators[descriptor.identifier]?.value {
                return existing
            }
            let coordinator = E2eeBackgroundTransferCoordinator(
                descriptor: descriptor,
                rootURL: rootURL,
                applicationGroupIdentifier: applicationGroupIdentifier
            )
            coordinators[descriptor.identifier] = WeakBackgroundTransferCoordinator(coordinator)
            return coordinator
        }
    }
}
