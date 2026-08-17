//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Drains only receive-side download callbacks. Upload callbacks remain in the shared journal for
/// `E2eeBackgroundTransferEventDrainer`, so neither state machine can consume the other's proof.
final class E2eeBackgroundDownloadEventDrainer {
    private let store: E2eeDurableBackgroundDownloadStore
    private let fileStore: E2eeBackgroundDownloadFileStore
    private let journal: BackgroundTransferEventJournal

    init(
        store: E2eeDurableBackgroundDownloadStore,
        fileStore: E2eeBackgroundDownloadFileStore,
        journal: BackgroundTransferEventJournal
    ) {
        self.store = store
        self.fileStore = fileStore
        self.journal = journal
    }

    @discardableResult
    func drain() throws -> Int {
        // Hydration is intentionally first. Before first unlock this can fail while the opaque
        // callback and ciphertext inbox remain durable and untouched.
        _ = try store.hydrate()
        let events = try journal.readAll()
        var applied = Set<String>()

        for event in events {
            guard event.resolvedOperation == .download else { continue }
            guard let record = try store.record(taskToken: event.taskToken) else {
                try? fileStore.removeCallbackFile(
                    taskToken: event.taskToken,
                    taskIdentifier: event.taskIdentifier
                )
                applied.insert(event.eventId)
                continue
            }
            guard record.taskIdentifier == event.taskIdentifier else {
                try? fileStore.removeCallbackFile(
                    taskToken: event.taskToken,
                    taskIdentifier: event.taskIdentifier
                )
                applied.insert(event.eventId)
                continue
            }
            if record.phase.isTerminal {
                try? fileStore.removeCallbackFile(
                    taskToken: event.taskToken,
                    taskIdentifier: event.taskIdentifier
                )
                applied.insert(event.eventId)
                continue
            }

            if event.kind == .progress {
                _ = try store.update(downloadId: record.downloadId) { updated in
                    updated.completedCiphertextBytes = max(
                        updated.completedCiphertextBytes,
                        min(updated.expectedCiphertextSize, event.completedBytes)
                    )
                    updated.phase = .downloading
                    updated.fixedError = nil
                }
                applied.insert(event.eventId)
                continue
            }

            if event.error != .none {
                _ = try store.update(downloadId: record.downloadId) { updated in
                    if event.error == .canceled {
                        updated.phase = .canceled
                    } else {
                        updated.phase = .failedRetryable
                    }
                    updated.fixedError = event.error
                }
                try? fileStore.removeCallbackFile(
                    taskToken: event.taskToken,
                    taskIdentifier: event.taskIdentifier
                )
                applied.insert(event.eventId)
                continue
            }

            guard let status = event.httpStatus else {
                _ = try store.update(downloadId: record.downloadId) { updated in
                    updated.phase = .failedTerminal
                    updated.fixedError = .unknown
                }
                applied.insert(event.eventId)
                continue
            }
            guard (200...299).contains(status) else {
                let retryable = status == 401
                    || status == 403
                    || status == 408
                    || status == 429
                    || (500...599).contains(status)
                _ = try store.update(downloadId: record.downloadId) { updated in
                    updated.phase = retryable ? .failedRetryable : .failedTerminal
                    updated.fixedError = retryable ? .httpServer : .httpClient
                }
                try? fileStore.removeCallbackFile(
                    taskToken: event.taskToken,
                    taskIdentifier: event.taskIdentifier
                )
                applied.insert(event.eventId)
                continue
            }

            do {
                let verifiedURL = try fileStore.promoteVerified(record: record)
                _ = try store.update(downloadId: record.downloadId) { updated in
                    updated.completedCiphertextBytes = updated.expectedCiphertextSize
                    updated.phase = .waitingForUnlock
                    updated.fixedError = nil
                    updated.verifiedCiphertextURL = verifiedURL
                }
                applied.insert(event.eventId)
            } catch E2eeBackgroundDownloadFileStoreError.callbackFileMissing {
                // Do not compact the completion proof. A process interruption can persist the
                // journal before didFinishDownloading has promoted the URLSession temp file.
                continue
            } catch {
                _ = try store.update(downloadId: record.downloadId) { updated in
                    updated.phase = .failedTerminal
                    updated.fixedError = .unknown
                }
                try? fileStore.removeCallbackFile(
                    taskToken: event.taskToken,
                    taskIdentifier: event.taskIdentifier
                )
                applied.insert(event.eventId)
            }
        }

        if !applied.isEmpty {
            try journal.compact(removingEventIds: applied)
        }
        return applied.count
    }
}
