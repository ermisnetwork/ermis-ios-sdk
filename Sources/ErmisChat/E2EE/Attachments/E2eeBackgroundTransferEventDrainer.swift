//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Applies opaque callbacks only after the protected transfer store has hydrated. URLSession can
/// deliver callbacks earlier; those remain durable in the journal and are not dropped.
final class E2eeBackgroundTransferEventDrainer {
    private let store: E2eeDurableTransferStore
    private let journal: BackgroundTransferEventJournal

    init(store: E2eeDurableTransferStore, journal: BackgroundTransferEventJournal) {
        self.store = store
        self.journal = journal
    }

    @discardableResult
    func drain() throws -> Int {
        _ = try store.hydrate()
        let events = try journal.readAll()
        var applied = Set<String>()
        for event in events {
            guard let attempt = try store.attempt(taskToken: event.taskToken) else {
                // A callback from a replaced/canceled attempt is intentionally consumed without
                // mutating any current attempt.
                applied.insert(event.eventId)
                continue
            }
            guard Self.matchesExactTask(event, in: attempt) else {
                applied.insert(event.eventId)
                continue
            }
            if attempt.phase == .canceled || attempt.phase == .confirmed || attempt.phase == .failedTerminal {
                applied.insert(event.eventId)
                continue
            }
            _ = try store.update(attemptId: attempt.attemptId) { record in
                let isLateMissingTaskCompletion = event.kind == .completion
                    && event.error == .none
                    && event.httpStatus.map { (200...299).contains($0) } == true
                    && record.phase == .failedRetryable
                    && record.failureReason == .backgroundTaskMissing
                Self.recordTransportProgress(event, in: &record)
                record.totalBytes = max(record.totalBytes, Self.aggregateTotalBytes(record))
                record.completedBytes = max(
                    record.completedBytes,
                    Self.aggregateCompletedBytes(record)
                )
                if event.kind == .progress {
                    return
                } else if event.error != .none {
                    if event.error == .canceled {
                        record.phase = .canceled
                        record.failureReason = nil
                    } else {
                        record.phase = .failedRetryable
                        record.failureReason = Self.failureReason(for: event.error)
                    }
                } else if event.httpStatus == nil {
                    record.phase = .failedTerminal
                    record.failureReason = .invalidServerResponse
                } else if let status = event.httpStatus, !(200...299).contains(status) {
                    let isRetryable = status == 401
                        || status == 403
                        || status == 408
                        || status == 429
                        || (500...599).contains(status)
                    record.phase = isRetryable ? .failedRetryable : .failedTerminal
                    record.failureReason = (status == 401 || status == 403)
                        ? .uploadExpired
                        : (isRetryable ? .networkUnavailable : .invalidServerResponse)
                } else if event.httpStatus != nil,
                          Self.isMultipartPart(taskToken: event.taskToken, in: record),
                          event.eTag == nil {
                    record.phase = .failedTerminal
                    record.failureReason = .invalidServerResponse
                } else {
                    Self.markUploadCompleted(
                        eTag: event.eTag,
                        taskToken: event.taskToken,
                        in: &record
                    )
                    if Self.allTransportUploadsComplete(record) {
                        // The successful HTTP callback is the durable transport authority. Move
                        // directly to service completion instead of waiting for a later
                        // `getAllTasks()` pass to notice that URLSession removed the final task.
                        record.phase = .finalizing
                        record.failureReason = nil
                    } else if isLateMissingTaskCompletion {
                        record.phase = .uploading
                        record.failureReason = nil
                    }
                }
                record.completedBytes = max(
                    record.completedBytes,
                    Self.aggregateCompletedBytes(record)
                )
            }
            // The record update (including ETag) is durable before the event is removed.
            applied.insert(event.eventId)
        }
        if !applied.isEmpty {
            try journal.compact(removingEventIds: applied)
        }
        return applied.count
    }

    private static func matchesExactTask(
        _ event: BackgroundTransferEvent,
        in attempt: PendingE2eeTransferAttempt
    ) -> Bool {
        for asset in attempt.assets {
            if asset.taskToken == event.taskToken {
                return asset.taskIdentifier == event.taskIdentifier
            }
            for part in asset.parts where part.taskToken == event.taskToken {
                return part.taskIdentifier == event.taskIdentifier
            }
        }
        return false
    }

    private static func markUploadCompleted(
        eTag: String?,
        taskToken: String,
        in attempt: inout PendingE2eeTransferAttempt
    ) {
        for assetIndex in attempt.assets.indices {
            if attempt.assets[assetIndex].taskToken == taskToken {
                attempt.assets[assetIndex].isUploaded = true
                attempt.assets[assetIndex].completedBytes = Int64(
                    clamping: attempt.assets[assetIndex].ciphertextSize ?? 0
                )
                attempt.assets[assetIndex].taskIdentifier = nil
                attempt.assets[assetIndex].taskToken = nil
                return
            }
            for partIndex in attempt.assets[assetIndex].parts.indices
            where attempt.assets[assetIndex].parts[partIndex].taskToken == taskToken {
                attempt.assets[assetIndex].parts[partIndex].eTag = eTag
                attempt.assets[assetIndex].parts[partIndex].completedBytes = Int64(
                    clamping: attempt.assets[assetIndex].parts[partIndex].size
                )
                attempt.assets[assetIndex].parts[partIndex].taskIdentifier = nil
                attempt.assets[assetIndex].parts[partIndex].taskToken = nil
                return
            }
        }
    }

    private static func isMultipartPart(
        taskToken: String,
        in attempt: PendingE2eeTransferAttempt
    ) -> Bool {
        attempt.assets.contains { asset in
            asset.parts.contains(where: { $0.taskToken == taskToken })
        }
    }

    private static func recordTransportProgress(
        _ event: BackgroundTransferEvent,
        in attempt: inout PendingE2eeTransferAttempt
    ) {
        for assetIndex in attempt.assets.indices {
            if attempt.assets[assetIndex].taskToken == event.taskToken {
                let limit = Int64(clamping: attempt.assets[assetIndex].ciphertextSize ?? 0)
                attempt.assets[assetIndex].completedBytes = max(
                    attempt.assets[assetIndex].completedBytes ?? 0,
                    min(limit, max(0, event.completedBytes))
                )
                return
            }
            for partIndex in attempt.assets[assetIndex].parts.indices
            where attempt.assets[assetIndex].parts[partIndex].taskToken == event.taskToken {
                let limit = Int64(clamping: attempt.assets[assetIndex].parts[partIndex].size)
                attempt.assets[assetIndex].parts[partIndex].completedBytes = max(
                    attempt.assets[assetIndex].parts[partIndex].completedBytes ?? 0,
                    min(limit, max(0, event.completedBytes))
                )
                return
            }
        }
    }

    private static func aggregateCompletedBytes(_ attempt: PendingE2eeTransferAttempt) -> Int64 {
        attempt.assets.reduce(Int64(0)) { total, asset in
            let assetProgress: Int64
            if asset.uploadMode == .multipart {
                assetProgress = asset.parts.reduce(Int64(0)) { partial, part in
                    let partCompletedBytes = part.completedBytes ?? 0
                    return partial.addingReportingOverflow(partCompletedBytes).overflow
                        ? Int64.max
                        : partial + partCompletedBytes
                }
            } else {
                assetProgress = asset.completedBytes ?? 0
            }
            let (sum, overflow) = total.addingReportingOverflow(assetProgress)
            return overflow ? Int64.max : sum
        }
    }

    private static func aggregateTotalBytes(_ attempt: PendingE2eeTransferAttempt) -> Int64 {
        let total = attempt.assets.reduce(UInt64(0)) { partial, asset in
            let (sum, overflow) = partial.addingReportingOverflow(asset.ciphertextSize ?? 0)
            return overflow ? UInt64.max : sum
        }
        return Int64(clamping: total)
    }

    private static func allTransportUploadsComplete(
        _ attempt: PendingE2eeTransferAttempt
    ) -> Bool {
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

    private static func failureReason(
        for error: BackgroundTransferFixedError
    ) -> E2eeTransferFailureReason {
        switch error {
        case .none:
            return .unknown
        case .canceled:
            return .canceledByUser
        case .timedOut, .networkLost, .cannotConnect, .notConnected:
            return .networkUnavailable
        case .httpClient, .httpServer, .unknown:
            return .unknown
        }
    }
}
