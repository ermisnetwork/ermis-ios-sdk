//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeDurableTransferStoreError: Error, Equatable {
    case duplicateAttempt
    case attemptNotFound
    case duplicateTaskToken
    case invalidRecordFile
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
