//
// Copyright 2026 Ermis Inc.
//

import Foundation
import open_mls_ios

struct MlsProviderStoreSnapshot: Equatable {
    let identity: Data?
    let groupIds: [String]
}

protocol MlsProviderStoreVerifying {
    func snapshot(databaseURL: URL) throws -> MlsProviderStoreSnapshot
}

struct OpenMlsProviderStoreVerifier: MlsProviderStoreVerifying {
    func snapshot(databaseURL: URL) throws -> MlsProviderStoreSnapshot {
        let provider = try Provider.newWithPath(dbPath: databaseURL.path)
        let identity = try provider.loadIdentity()
        let groupIds = try provider.storedGroupIds().sorted()
        return MlsProviderStoreSnapshot(identity: identity, groupIds: groupIds)
    }
}

struct MlsProviderStoreMigrator {
    enum InterruptionPhase: Equatable {
        case afterCopy
        case afterVerification
        case afterPromotionBeforeMarker
    }

    enum MigrationError: Error {
        case noUsableStore
        case verificationMismatch
        case simulatedInterruption(InterruptionPhase)
    }

    private static let sqliteSuffixes = ["", "-wal", "-shm"]
    private static let stagingPrefix = ".mls-provider-migration-"

    let fileManager: FileManager
    let defaults: UserDefaults
    let verifier: MlsProviderStoreVerifying
    let interruptAfterPhase: InterruptionPhase?

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults,
        verifier: MlsProviderStoreVerifying = OpenMlsProviderStoreVerifier(),
        interruptAfterPhase: InterruptionPhase? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.verifier = verifier
        self.interruptAfterPhase = interruptAfterPhase
    }

    /// Resolves the provider database without ever replacing a usable legacy store with a blank
    /// destination. Migration copies into a staging directory, verifies identity and group IDs,
    /// promotes the verified SQLite set, and writes the marker last.
    func resolveDatabaseURL(
        legacyCandidates: [URL],
        destinationURL: URL,
        markerKey: String
    ) throws -> URL {
        let candidates = uniqueExistingCandidates(legacyCandidates, excluding: destinationURL)
        let legacyURL = candidates.first
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        let migrationCompleted = defaults.bool(forKey: markerKey)

        if migrationCompleted {
            if destinationExists { return destinationURL }
            if let legacyURL {
                defaults.removeObject(forKey: markerKey)
                do {
                    return try migrate(
                        legacyURL: legacyURL,
                        destinationURL: destinationURL,
                        markerKey: markerKey
                    )
                } catch {
                    return legacyURL
                }
            }
            throw MigrationError.noUsableStore
        }

        if let legacyURL, destinationExists {
            do {
                guard try verifier.snapshot(databaseURL: legacyURL)
                    == verifier.snapshot(databaseURL: destinationURL) else {
                    throw MigrationError.verificationMismatch
                }
                try protectStore(at: destinationURL)
                defaults.set(true, forKey: markerKey)
                try? removeStaleStagingDirectories(
                    in: destinationURL.deletingLastPathComponent()
                )
                return destinationURL
            } catch {
                // Destination may be a partial promotion left by a process kill. Keep the legacy
                // store untouched and retry a clean staged copy below.
                try? removeSQLiteSet(at: destinationURL)
            }
        }

        guard let legacyURL else {
            try prepareDestinationDirectory(destinationURL.deletingLastPathComponent())
            return destinationURL
        }

        do {
            return try migrate(
                legacyURL: legacyURL,
                destinationURL: destinationURL,
                markerKey: markerKey
            )
        } catch let error as MigrationError {
            if case .simulatedInterruption = error { throw error }
            return legacyURL
        } catch {
            return legacyURL
        }
    }

    private func migrate(
        legacyURL: URL,
        destinationURL: URL,
        markerKey: String
    ) throws -> URL {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try prepareDestinationDirectory(destinationDirectory)
        try removeStaleStagingDirectories(in: destinationDirectory)

        // Opening and releasing the legacy provider before copying gives SQLite a chance to
        // checkpoint its WAL and proves that the fallback store is readable.
        let expected = try verifier.snapshot(databaseURL: legacyURL)
        let stagingDirectory = destinationDirectory.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: nil
        )
        let stagedURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)

        do {
            try copySQLiteSet(from: legacyURL, to: stagedURL)
            try interruptIfNeeded(.afterCopy)

            guard try verifier.snapshot(databaseURL: stagedURL) == expected else {
                throw MigrationError.verificationMismatch
            }
            try interruptIfNeeded(.afterVerification)

            try removeSQLiteSet(at: destinationURL)
            try promoteSQLiteSet(from: stagedURL, to: destinationURL)
            try protectStore(at: destinationURL)
            try interruptIfNeeded(.afterPromotionBeforeMarker)

            defaults.set(true, forKey: markerKey)
            try? fileManager.removeItem(at: stagingDirectory)
            return destinationURL
        } catch {
            if let migrationError = error as? MigrationError,
               case .simulatedInterruption = migrationError {
                throw error
            }
            try? fileManager.removeItem(at: stagingDirectory)
            try? removeSQLiteSet(at: destinationURL)
            throw error
        }
    }

    private func uniqueExistingCandidates(_ candidates: [URL], excluding destinationURL: URL) -> [URL] {
        var paths = Set<String>()
        return candidates.filter { candidate in
            let path = candidate.standardizedFileURL.path
            guard path != destinationURL.standardizedFileURL.path,
                  paths.insert(path).inserted else { return false }
            return fileManager.fileExists(atPath: path)
        }
    }

    private func prepareDestinationDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
#endif
    }

    private func copySQLiteSet(from sourceURL: URL, to destinationURL: URL) throws {
        for suffix in Self.sqliteSuffixes {
            let source = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func promoteSQLiteSet(from sourceURL: URL, to destinationURL: URL) throws {
        for suffix in Self.sqliteSuffixes {
            let source = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private func removeSQLiteSet(at databaseURL: URL) throws {
        for suffix in Self.sqliteSuffixes {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func protectStore(at databaseURL: URL) throws {
        for suffix in Self.sqliteSuffixes {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
#if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
#endif
        }
    }

    func protectResolvedStore(at databaseURL: URL) throws {
        // The destination directory was prepared before migration/provider creation. A fallback
        // can point at Documents, whose parent must never be excluded from backup as a whole.
        try protectStore(at: databaseURL)
    }

    private func removeStaleStagingDirectories(in directory: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents where url.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            try fileManager.removeItem(at: url)
        }
    }

    private func interruptIfNeeded(_ phase: InterruptionPhase) throws {
        guard interruptAfterPhase == phase else { return }
        throw MigrationError.simulatedInterruption(phase)
    }
}
