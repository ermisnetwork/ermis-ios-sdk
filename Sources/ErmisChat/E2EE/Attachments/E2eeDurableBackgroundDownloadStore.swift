//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation

enum E2eeBackgroundDownloadPhase: String, Codable, Sendable {
    case scheduled
    case downloading
    case waitingForUnlock
    case failedRetryable
    case failedTerminal
    case canceled
    case completed

    var isTerminal: Bool {
        switch self {
        case .failedTerminal, .canceled, .completed:
            return true
        case .scheduled, .downloading, .waitingForUnlock, .failedRetryable:
            return false
        }
    }
}

struct E2eeDurableBackgroundDownload: Codable, Equatable, Sendable {
    let downloadId: String
    let accountId: String
    let cid: String
    let attachmentId: String
    let assetId: String
    let taskToken: String
    var taskIdentifier: Int?
    let expectedCiphertextSize: Int64
    let expectedCiphertextSha256: String
    var completedCiphertextBytes: Int64
    var phase: E2eeBackgroundDownloadPhase
    var fixedError: BackgroundTransferFixedError?
    var verifiedCiphertextURL: URL?
    let createdAt: Date
    var updatedAt: Date

    init(
        downloadId: String = UUID().uuidString,
        accountId: String,
        cid: String,
        attachmentId: String,
        assetId: String,
        taskToken: String = UUID().uuidString,
        taskIdentifier: Int? = nil,
        expectedCiphertextSize: Int64,
        expectedCiphertextSha256: String,
        completedCiphertextBytes: Int64 = 0,
        phase: E2eeBackgroundDownloadPhase = .scheduled,
        fixedError: BackgroundTransferFixedError? = nil,
        verifiedCiphertextURL: URL? = nil,
        now: Date = Date()
    ) {
        self.downloadId = downloadId
        self.accountId = accountId
        self.cid = cid
        self.attachmentId = attachmentId
        self.assetId = assetId
        self.taskToken = taskToken
        self.taskIdentifier = taskIdentifier
        self.expectedCiphertextSize = expectedCiphertextSize
        self.expectedCiphertextSha256 = expectedCiphertextSha256.lowercased()
        self.completedCiphertextBytes = completedCiphertextBytes
        self.phase = phase
        self.fixedError = fixedError
        self.verifiedCiphertextURL = verifiedCiphertextURL
        createdAt = now
        updatedAt = now
    }
}

enum E2eeDurableBackgroundDownloadStoreError: Error, Equatable {
    case duplicateDownload
    case duplicateTaskToken
    case downloadNotFound
    case invalidRecord
    case progressRegression
}

/// Protected logical download state. This store is deliberately independent from outgoing upload
/// attempts so a receive-side callback can never advance the message-send state machine.
final class E2eeDurableBackgroundDownloadStore {
    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootURL: URL, fileManager: FileManager = .default) {
        directory = rootURL
            .appendingPathComponent("background-downloads", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        self.fileManager = fileManager
    }

    func hydrate() throws -> [E2eeDurableBackgroundDownload] {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadAllLocked()
        }
    }

    func insert(_ record: E2eeDurableBackgroundDownload) throws {
        try lock.withLock {
            try prepareDirectoryLocked()
            try Self.validate(record)
            guard !fileManager.fileExists(atPath: recordURL(downloadId: record.downloadId).path) else {
                throw E2eeDurableBackgroundDownloadStoreError.duplicateDownload
            }
            guard try loadAllLocked().allSatisfy({ $0.taskToken != record.taskToken }) else {
                throw E2eeDurableBackgroundDownloadStoreError.duplicateTaskToken
            }
            try writeLocked(record)
        }
    }

    /// Atomically persists a new logical download or returns the newest byte-identical attempt.
    /// This closes the race where two viewers request the same original before either caller has
    /// observed the other's protected record.
    func insertOrExisting(
        _ record: E2eeDurableBackgroundDownload
    ) throws -> (record: E2eeDurableBackgroundDownload, inserted: Bool) {
        try lock.withLock {
            try prepareDirectoryLocked()
            try Self.validate(record)
            let records = try loadAllLocked()
            if let existing = records
                .filter({ Self.isSameLogicalDownload($0, record) })
                .max(by: { $0.createdAt < $1.createdAt }) {
                return (existing, false)
            }
            guard records.allSatisfy({ $0.downloadId != record.downloadId }) else {
                throw E2eeDurableBackgroundDownloadStoreError.duplicateDownload
            }
            guard records.allSatisfy({ $0.taskToken != record.taskToken }) else {
                throw E2eeDurableBackgroundDownloadStoreError.duplicateTaskToken
            }
            try writeLocked(record)
            return (record, true)
        }
    }

    @discardableResult
    func update(
        downloadId: String,
        _ mutation: (inout E2eeDurableBackgroundDownload) throws -> Void
    ) throws -> E2eeDurableBackgroundDownload {
        try lock.withLock {
            try prepareDirectoryLocked()
            let previous = try loadLocked(downloadId: downloadId)
            var updated = previous
            try mutation(&updated)
            guard updated.completedCiphertextBytes >= previous.completedCiphertextBytes else {
                throw E2eeDurableBackgroundDownloadStoreError.progressRegression
            }
            updated.updatedAt = Date()
            try Self.validate(updated)
            try writeLocked(updated)
            return updated
        }
    }

    func record(taskToken: String) throws -> E2eeDurableBackgroundDownload? {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadAllLocked().first(where: { $0.taskToken == taskToken })
        }
    }

    func record(downloadId: String) throws -> E2eeDurableBackgroundDownload? {
        try lock.withLock {
            try prepareDirectoryLocked()
            let url = recordURL(downloadId: downloadId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decodeLocked(url)
        }
    }

    func newestRecord(
        accountId: String,
        cid: String,
        attachmentId: String,
        assetId: String,
        expectedCiphertextSize: Int64,
        expectedCiphertextSha256: String
    ) throws -> E2eeDurableBackgroundDownload? {
        try lock.withLock {
            try prepareDirectoryLocked()
            let probe = E2eeDurableBackgroundDownload(
                accountId: accountId,
                cid: cid,
                attachmentId: attachmentId,
                assetId: assetId,
                expectedCiphertextSize: expectedCiphertextSize,
                expectedCiphertextSha256: expectedCiphertextSha256
            )
            return try loadAllLocked()
                .filter { Self.isSameLogicalDownload($0, probe) }
                .max(by: { $0.createdAt < $1.createdAt })
        }
    }

    func records(accountId: String) throws -> [E2eeDurableBackgroundDownload] {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadAllLocked().filter { $0.accountId == accountId }
        }
    }

    func records(
        accountId: String,
        cid: String,
        attachmentId: String,
        assetId: String
    ) throws -> [E2eeDurableBackgroundDownload] {
        try lock.withLock {
            try prepareDirectoryLocked()
            return try loadAllLocked().filter {
                $0.accountId == accountId
                    && $0.cid == cid
                    && $0.attachmentId.caseInsensitiveCompare(attachmentId) == .orderedSame
                    && $0.assetId.caseInsensitiveCompare(assetId) == .orderedSame
            }
        }
    }

    func remove(downloadId: String) throws {
        try lock.withLock {
            let url = recordURL(downloadId: downloadId)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    private func loadLocked(downloadId: String) throws -> E2eeDurableBackgroundDownload {
        let url = recordURL(downloadId: downloadId)
        guard fileManager.fileExists(atPath: url.path) else {
            throw E2eeDurableBackgroundDownloadStoreError.downloadNotFound
        }
        return try decodeLocked(url)
    }

    private func loadAllLocked() throws -> [E2eeDurableBackgroundDownload] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map(decodeLocked)
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func decodeLocked(_ url: URL) throws -> E2eeDurableBackgroundDownload {
        do {
            let record = try JSONDecoder.default.decode(
                E2eeDurableBackgroundDownload.self,
                from: Data(contentsOf: url)
            )
            try Self.validate(record)
            return record
        } catch let error as E2eeDurableBackgroundDownloadStoreError {
            throw error
        } catch {
            throw E2eeDurableBackgroundDownloadStoreError.invalidRecord
        }
    }

    private func writeLocked(_ record: E2eeDurableBackgroundDownload) throws {
        let destination = recordURL(downloadId: record.downloadId)
        let partial = directory.appendingPathComponent(
            ".\(record.downloadId).\(UUID().uuidString).partial"
        )
        do {
            try JSONEncoder.default.encode(record).write(to: partial, options: [.withoutOverwriting])
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

    private func recordURL(downloadId: String) -> URL {
        directory.appendingPathComponent(downloadId + ".json")
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

    private static func validate(_ record: E2eeDurableBackgroundDownload) throws {
        guard UUID(uuidString: record.downloadId) != nil,
              UUID(uuidString: record.taskToken) != nil,
              !record.accountId.isEmpty,
              !record.cid.isEmpty,
              !record.attachmentId.isEmpty,
              !record.assetId.isEmpty,
              record.taskIdentifier.map({ $0 >= 0 }) ?? true,
              record.expectedCiphertextSize > 0,
              record.completedCiphertextBytes >= 0,
              record.completedCiphertextBytes <= record.expectedCiphertextSize,
              record.expectedCiphertextSha256.count == 64,
              record.expectedCiphertextSha256.allSatisfy({ $0.isHexDigit }) else {
            throw E2eeDurableBackgroundDownloadStoreError.invalidRecord
        }
    }

    private static func isSameLogicalDownload(
        _ lhs: E2eeDurableBackgroundDownload,
        _ rhs: E2eeDurableBackgroundDownload
    ) -> Bool {
        lhs.accountId == rhs.accountId
            && lhs.cid == rhs.cid
            && lhs.attachmentId.caseInsensitiveCompare(rhs.attachmentId) == .orderedSame
            && lhs.assetId.caseInsensitiveCompare(rhs.assetId) == .orderedSame
            && lhs.expectedCiphertextSize == rhs.expectedCiphertextSize
            && lhs.expectedCiphertextSha256.caseInsensitiveCompare(rhs.expectedCiphertextSha256) == .orderedSame
    }
}

enum E2eeBackgroundDownloadFileStoreError: Error, Equatable {
    case invalidOpaqueToken
    case callbackFileMissing
    case ciphertextSizeMismatch
    case ciphertextHashMismatch
}

/// The URLSession callback location is transient. Capture it synchronously into an opaque,
/// no-protection inbox so callbacks delivered before first unlock survive. Only ciphertext is
/// allowed here. After protected state hydrates, bytes are verified and promoted immediately.
final class E2eeBackgroundDownloadFileStore {
    private let callbackInboxDirectory: URL
    private let verifiedDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootURL: URL, fileManager: FileManager = .default) {
        callbackInboxDirectory = rootURL
            .appendingPathComponent("background-download-callback-inbox", isDirectory: true)
        verifiedDirectory = rootURL
            .appendingPathComponent("background-downloads", isDirectory: true)
            .appendingPathComponent("verified", isDirectory: true)
        self.fileManager = fileManager
    }

    func captureTemporaryFile(
        at temporaryURL: URL,
        taskToken: String,
        taskIdentifier: Int
    ) throws -> URL {
        try lock.withLock {
            try validate(taskToken: taskToken, taskIdentifier: taskIdentifier)
            try prepareCallbackInboxLocked()
            let destination = callbackURL(taskToken: taskToken, taskIdentifier: taskIdentifier)
            let partial = callbackInboxDirectory.appendingPathComponent(
                ".\(taskToken)-\(taskIdentifier).\(UUID().uuidString).partial"
            )
            do {
                if fileManager.fileExists(atPath: partial.path) {
                    try fileManager.removeItem(at: partial)
                }
                try fileManager.moveItem(at: temporaryURL, to: partial)
                try setNoProtectionLocked(partial)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try fileManager.moveItem(at: partial, to: destination)
                }
                try setNoProtectionLocked(destination)
                return destination
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
        }
    }

    func promoteVerified(
        record: E2eeDurableBackgroundDownload
    ) throws -> URL {
        try lock.withLock {
            let source = callbackURL(
                taskToken: record.taskToken,
                taskIdentifier: try requiredTaskIdentifier(record.taskIdentifier)
            )
            guard fileManager.fileExists(atPath: source.path) else {
                throw E2eeBackgroundDownloadFileStoreError.callbackFileMissing
            }
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            guard let byteCount = attributes[.size] as? NSNumber,
                  byteCount.int64Value == record.expectedCiphertextSize else {
                throw E2eeBackgroundDownloadFileStoreError.ciphertextSizeMismatch
            }
            guard try sha256Hex(of: source) == record.expectedCiphertextSha256 else {
                throw E2eeBackgroundDownloadFileStoreError.ciphertextHashMismatch
            }
            try prepareVerifiedDirectoryLocked()
            let destination = verifiedDirectory.appendingPathComponent(record.downloadId + ".cipher")
            let partial = verifiedDirectory.appendingPathComponent(
                ".\(record.downloadId).\(UUID().uuidString).partial"
            )
            do {
                try fileManager.moveItem(at: source, to: partial)
                try protectLocked(partial)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try fileManager.moveItem(at: partial, to: destination)
                }
                try protectLocked(destination)
                return destination
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
        }
    }

    func removeCallbackFile(taskToken: String, taskIdentifier: Int) throws {
        try lock.withLock {
            try validate(taskToken: taskToken, taskIdentifier: taskIdentifier)
            let url = callbackURL(taskToken: taskToken, taskIdentifier: taskIdentifier)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    func verifiedFileURL(downloadId: String) -> URL? {
        lock.withLock {
            let url = verifiedDirectory.appendingPathComponent(downloadId + ".cipher")
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }

    func removeVerifiedFile(downloadId: String) throws {
        try lock.withLock {
            let url = verifiedDirectory.appendingPathComponent(downloadId + ".cipher")
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    func removeFiles(for record: E2eeDurableBackgroundDownload) {
        try? removeVerifiedFile(downloadId: record.downloadId)
        if let taskIdentifier = record.taskIdentifier {
            try? removeCallbackFile(
                taskToken: record.taskToken,
                taskIdentifier: taskIdentifier
            )
        }
    }

    private func callbackURL(taskToken: String, taskIdentifier: Int) -> URL {
        callbackInboxDirectory.appendingPathComponent("\(taskToken)-\(taskIdentifier).cipher")
    }

    private func prepareCallbackInboxLocked() throws {
        try fileManager.createDirectory(at: callbackInboxDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = callbackInboxDirectory
        try mutableDirectory.setResourceValues(values)
        try setNoProtectionLocked(callbackInboxDirectory)
    }

    private func prepareVerifiedDirectoryLocked() throws {
        try fileManager.createDirectory(at: verifiedDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = verifiedDirectory
        try mutableDirectory.setResourceValues(values)
        try protectLocked(verifiedDirectory)
    }

    private func requiredTaskIdentifier(_ value: Int?) throws -> Int {
        guard let value else { throw E2eeDurableBackgroundDownloadStoreError.invalidRecord }
        return value
    }

    private func validate(taskToken: String, taskIdentifier: Int) throws {
        guard UUID(uuidString: taskToken) != nil, taskIdentifier >= 0 else {
            throw E2eeBackgroundDownloadFileStoreError.invalidOpaqueToken
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func setNoProtectionLocked(_ url: URL) throws {
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: url.path
        )
#endif
    }

    private func protectLocked(_ url: URL) throws {
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }
}
