//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeDurableTransferStoreError: Error, Equatable {
    case duplicateAttempt
    case attemptNotFound
    case duplicateTaskToken
    case invalidRecordFile
    case invalidExpiredUploadReset
}

/// A protected, excluded-from-backup record store hydrated before callback-journal drain. One file
/// per attempt keeps updates atomic and makes account-scoped logout independent across clients.
final class E2eeDurableTransferStore {
    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootURL: URL, fileManager: FileManager = .default) {
        directory = rootURL.appendingPathComponent("pending", isDirectory: true)
        self.fileManager = fileManager
    }

    func hydrate() throws -> [PendingE2eeTransferAttempt] {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadAllLocked()
        }
    }

    func insert(_ attempt: PendingE2eeTransferAttempt) throws {
        try lock.withLock {
            try prepareDirectoryLocked()
            try attempt.validate()
            guard !fileManager.fileExists(atPath: recordURL(attemptId: attempt.attemptId).path) else {
                throw E2eeDurableTransferStoreError.duplicateAttempt
            }
            let newTokens = Self.taskTokens(in: attempt)
            guard try loadAllLocked().allSatisfy({ Self.taskTokens(in: $0).isDisjoint(with: newTokens) }) else {
                throw E2eeDurableTransferStoreError.duplicateTaskToken
            }
            try writeLocked(attempt)
        }
    }

    @discardableResult
    func update(
        attemptId: String,
        _ mutation: (inout PendingE2eeTransferAttempt) throws -> Void
    ) throws -> PendingE2eeTransferAttempt {
        try lock.withLock {
            try prepareDirectoryLocked()
            let previous = try loadLocked(attemptId: attemptId)
            var updated = previous
            try mutation(&updated)
            updated.updatedAt = Date()
            try updated.validateUpdate(from: previous)
            try writeLocked(updated)
            return updated
        }
    }

    func attempt(taskToken: String) throws -> PendingE2eeTransferAttempt? {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadAllLocked().first(where: { attempt in
                attempt.taskToken == taskToken || attempt.assets.contains(where: { asset in
                    asset.taskToken == taskToken || asset.parts.contains(where: { $0.taskToken == taskToken })
                })
            })
        }
    }

    func attempt(attemptId: String) throws -> PendingE2eeTransferAttempt {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadLocked(attemptId: attemptId)
        }
    }

    /// Repairs records written by SDK builds that classified an iOS force-quit URLSession
    /// cancellation as explicit user intent. Callers must first prove the encrypted upload source
    /// and valid grant still exist; ordinary `.canceled` records remain terminal.
    func repairMisclassifiedForceQuitCancellation(
        attemptId: String
    ) throws -> PendingE2eeTransferAttempt {
        try lock.withLock {
            try prepareDirectoryLocked()
            let previous = try loadLocked(attemptId: attemptId)
            guard previous.phase == .canceled else { return previous }
            var repaired = previous
            repaired.phase = .failedRetryable
            repaired.failureReason = .backgroundTaskMissing
            repaired.updatedAt = Date()
            try repaired.validate()
            try writeLocked(repaired)
            return repaired
        }
    }

    /// Starts a new Bellboy init/idempotency attempt while retaining the exact canonical
    /// ciphertext and sealed attachment secret. This is the only supported progress reset: an
    /// expired presigned upload cannot reuse its server attachment IDs, URLs, multipart ETags, or
    /// byte progress, but re-encrypting would change the attachment payload unnecessarily.
    func resetExpiredUploadForFreshInit(
        attemptId: String
    ) throws -> PendingE2eeTransferAttempt {
        try lock.withLock {
            try prepareDirectoryLocked()
            let previous = try loadLocked(attemptId: attemptId)
            let hasReusableCiphertext = !previous.assets.isEmpty
                && previous.assets.allSatisfy({ asset in
                      guard let canonicalURL = asset.canonicalCiphertextURL,
                            let ciphertextSize = asset.ciphertextSize,
                            ciphertextSize >= UInt64(E2eeAttachmentFrameCryptoV1.emptyCiphertextSize) else {
                          return false
                      }
                      return fileManager.fileExists(atPath: canonicalURL.path)
                  })

            // A process may have died after this reset was persisted but before `/init` returned.
            // The same state also remains after a retryable `/init` failure. Reuse those pending
            // identifiers so the next Retry repeats the same idempotent init instead of leaking
            // another server attachment attempt.
            let alreadyReset = previous.assets.allSatisfy { asset in
                asset.uploadMode == nil
                    && asset.uploadExpiresAt == nil
                    && asset.putURL == nil
                    && asset.objectKey == nil
                    && asset.multipartUploadId == nil
                    && asset.parts.isEmpty
                    && asset.isUploaded == false
                    && UUID(uuidString: asset.idempotencyKey ?? "") != nil
            }
            guard previous.phase == .failedRetryable,
                  hasReusableCiphertext,
                  previous.failureReason == .uploadExpired || alreadyReset else {
                throw E2eeDurableTransferStoreError.invalidExpiredUploadReset
            }
            guard !alreadyReset else { return previous }

            var fresh = previous
            var logicalIdentifiers: [String: (attachmentId: String, idempotencyKey: String)] = [:]
            for index in fresh.assets.indices {
                let previousAttachmentId = fresh.assets[index].attachmentId
                let identifiers: (attachmentId: String, idempotencyKey: String)
                if let existing = logicalIdentifiers[previousAttachmentId] {
                    identifiers = existing
                } else {
                    identifiers = (UUID().uuidString, UUID().uuidString)
                    logicalIdentifiers[previousAttachmentId] = identifiers
                }

                fresh.assets[index].attachmentId = identifiers.attachmentId
                fresh.assets[index].assetId = UUID().uuidString
                fresh.assets[index].idempotencyKey = identifiers.idempotencyKey
                fresh.assets[index].uploadMode = nil
                fresh.assets[index].uploadExpiresAt = nil
                fresh.assets[index].putURL = nil
                fresh.assets[index].objectKey = nil
                fresh.assets[index].multipartUploadId = nil
                fresh.assets[index].multipartPartSize = nil
                fresh.assets[index].maxPartRetries = nil
                fresh.assets[index].retryMaxElapsedSeconds = nil
                fresh.assets[index].completedBytes = 0
                fresh.assets[index].taskIdentifier = nil
                fresh.assets[index].taskToken = nil
                fresh.assets[index].isUploaded = false
                fresh.assets[index].parts = []
            }
            fresh.completedBytes = 0
            fresh.completionIntents = nil
            fresh.updatedAt = Date()
            try fresh.validate()
            try writeLocked(fresh)
            return fresh
        }
    }

    func remove(attemptId: String) throws {
        try lock.withLock {
            let url = recordURL(attemptId: attemptId)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    func removeAll(accountId: String) throws -> [PendingE2eeTransferAttempt] {
        try lock.withLock {
            try prepareDirectoryLocked()
            let attempts = try loadAllLocked().filter { $0.accountId == accountId }
            for attempt in attempts {
                try fileManager.removeItem(at: recordURL(attemptId: attempt.attemptId))
            }
            return attempts
        }
    }

    private func loadLocked(attemptId: String) throws -> PendingE2eeTransferAttempt {
        let url = recordURL(attemptId: attemptId)
        guard fileManager.fileExists(atPath: url.path) else {
            throw E2eeDurableTransferStoreError.attemptNotFound
        }
        return try decodeLocked(url)
    }

    private func loadAllLocked() throws -> [PendingE2eeTransferAttempt] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map(decodeLocked)
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func decodeLocked(_ url: URL) throws -> PendingE2eeTransferAttempt {
        do {
            let record = try JSONDecoder.default.decode(
                PendingE2eeTransferAttempt.self,
                from: Data(contentsOf: url)
            )
            try record.validate()
            return record
        } catch let error as E2eeTransferStateError {
            throw error
        } catch {
            throw E2eeDurableTransferStoreError.invalidRecordFile
        }
    }

    private func writeLocked(_ attempt: PendingE2eeTransferAttempt) throws {
        let destination = recordURL(attemptId: attempt.attemptId)
        let partial = directory.appendingPathComponent(
            ".\(attempt.attemptId).\(UUID().uuidString).partial"
        )
        do {
            let data = try JSONEncoder.default.encode(attempt)
            try data.write(to: partial, options: [.withoutOverwriting])
            try protectLocked(partial)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            try protectLocked(destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func recordURL(attemptId: String) -> URL {
        directory.appendingPathComponent(attemptId + ".json")
    }

    private func prepareDirectoryLocked() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        try protectLocked(directory)
    }

    private func protectLocked(_ url: URL) throws {
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    private static func taskTokens(in attempt: PendingE2eeTransferAttempt) -> Set<String> {
        Set(
            [attempt.taskToken] + attempt.assets.flatMap { asset in
                [asset.taskToken].compactMap { $0 } + asset.parts.compactMap(\.taskToken)
            }
        )
    }
}
