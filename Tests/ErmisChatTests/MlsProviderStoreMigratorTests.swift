//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import XCTest
@testable import ErmisChat
import open_mls_ios

final class MlsProviderStoreMigratorTests: XCTestCase {
    private struct ConstantVerifier: MlsProviderStoreVerifying {
        let value: MlsProviderStoreSnapshot

        func snapshot(databaseURL: URL) throws -> MlsProviderStoreSnapshot {
            value
        }
    }

    private struct StagingMismatchVerifier: MlsProviderStoreVerifying {
        let sourceURL: URL

        func snapshot(databaseURL: URL) throws -> MlsProviderStoreSnapshot {
            if databaseURL.standardizedFileURL == sourceURL.standardizedFileURL {
                return .init(identity: Data("legacy".utf8), groupIds: ["group"])
            }
            return .init(identity: Data("different".utf8), groupIds: [])
        }
    }

    private final class DeviceIdSecureStore: MlsDeviceIdSecureStoring {
        var values: [UserId: String] = [:]

        func load(userId: UserId) throws -> String? { values[userId] }
        func save(deviceId: String, userId: UserId) throws { values[userId] = deviceId }
        func remove(userId: UserId) throws { values.removeValue(forKey: userId) }
    }

#if os(iOS)
    private final class RecordingFileManager: FileManager, @unchecked Sendable {
        private(set) var protectedPaths: Set<String> = []

        override func setAttributes(
            _ attributes: [FileAttributeKey: Any],
            ofItemAtPath path: String
        ) throws {
            if attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication {
                protectedPaths.insert(path)
            }
            try super.setAttributes(attributes, ofItemAtPath: path)
        }
    }
#endif

    func testMigrationCopiesAndVerifiesOpenMlsIdentityAndGroups() throws {
        try withTemporaryMigration { legacyURL, destinationURL, defaults, markerKey in
            try makeOpenMlsStore(at: legacyURL, userId: "alice", groupIds: ["team:one", "team:two"])
            let expected = try OpenMlsProviderStoreVerifier().snapshot(databaseURL: legacyURL)

            let resolved = try MlsProviderStoreMigrator(defaults: defaults).resolveDatabaseURL(
                legacyCandidates: [legacyURL],
                destinationURL: destinationURL,
                markerKey: markerKey
            )

            XCTAssertEqual(resolved.standardizedFileURL, destinationURL.standardizedFileURL)
            XCTAssertEqual(
                try OpenMlsProviderStoreVerifier().snapshot(databaseURL: destinationURL),
                expected
            )
            XCTAssertTrue(defaults.bool(forKey: markerKey))
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
            XCTAssertEqual(
                try destinationURL.deletingLastPathComponent()
                    .resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup,
                true
            )
        }
    }

#if os(iOS)
    func testMigrationAppliesAfterFirstAuthenticationProtectionToDirectoryAndStore() throws {
        try withTemporaryMigration { legacyURL, destinationURL, defaults, markerKey in
            try Data("legacy".utf8).write(to: legacyURL)
            let fileManager = RecordingFileManager()
            let verifier = ConstantVerifier(value: .init(identity: nil, groupIds: []))

            _ = try MlsProviderStoreMigrator(
                fileManager: fileManager,
                defaults: defaults,
                verifier: verifier
            ).resolveDatabaseURL(
                legacyCandidates: [legacyURL],
                destinationURL: destinationURL,
                markerKey: markerKey
            )

            XCTAssertTrue(
                fileManager.protectedPaths.contains(
                    destinationURL.deletingLastPathComponent().path
                )
            )
            XCTAssertTrue(fileManager.protectedPaths.contains(destinationURL.path))
        }
    }
#endif

    func testMigrationCopiesSQLiteSidecarsWithoutDeletingLegacySet() throws {
        try withTemporaryMigration { legacyURL, destinationURL, defaults, markerKey in
            for suffix in ["", "-wal", "-shm"] {
                try Data("legacy\(suffix)".utf8).write(
                    to: URL(fileURLWithPath: legacyURL.path + suffix)
                )
            }
            let verifier = ConstantVerifier(value: .init(identity: nil, groupIds: []))

            _ = try MlsProviderStoreMigrator(
                defaults: defaults,
                verifier: verifier
            ).resolveDatabaseURL(
                legacyCandidates: [legacyURL],
                destinationURL: destinationURL,
                markerKey: markerKey
            )

            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: legacyURL.path + suffix)
                let destination = URL(fileURLWithPath: destinationURL.path + suffix)
                XCTAssertEqual(
                    try Data(contentsOf: destination),
                    try Data(contentsOf: source)
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            }
        }
    }

    func testVerificationFailureFallsBackToLegacyWithoutMarkerOrBlankDestination() throws {
        try withTemporaryMigration { legacyURL, destinationURL, defaults, markerKey in
            try Data("usable legacy".utf8).write(to: legacyURL)

            let resolved = try MlsProviderStoreMigrator(
                defaults: defaults,
                verifier: StagingMismatchVerifier(sourceURL: legacyURL)
            ).resolveDatabaseURL(
                legacyCandidates: [legacyURL],
                destinationURL: destinationURL,
                markerKey: markerKey
            )

            XCTAssertEqual(resolved.standardizedFileURL, legacyURL.standardizedFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
            XCTAssertFalse(defaults.bool(forKey: markerKey))
        }
    }

    func testRelaunchRecoversEveryMigrationInterruptionPhase() throws {
        for phase in [
            MlsProviderStoreMigrator.InterruptionPhase.afterCopy,
            .afterVerification,
            .afterPromotionBeforeMarker
        ] {
            try withTemporaryMigration { legacyURL, destinationURL, defaults, markerKey in
                try Data("legacy".utf8).write(to: legacyURL)
                let verifier = ConstantVerifier(
                    value: .init(identity: Data("identity".utf8), groupIds: ["group"])
                )
                let interrupted = MlsProviderStoreMigrator(
                    defaults: defaults,
                    verifier: verifier,
                    interruptAfterPhase: phase
                )

                XCTAssertThrowsError(
                    try interrupted.resolveDatabaseURL(
                        legacyCandidates: [legacyURL],
                        destinationURL: destinationURL,
                        markerKey: markerKey
                    )
                ) { error in
                    guard let migrationError = error as? MlsProviderStoreMigrator.MigrationError,
                          case .simulatedInterruption(let actualPhase) = migrationError else {
                        return XCTFail("Unexpected interruption error: \(error)")
                    }
                    XCTAssertEqual(actualPhase, phase)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
                XCTAssertFalse(defaults.bool(forKey: markerKey))

                let resolved = try MlsProviderStoreMigrator(
                    defaults: defaults,
                    verifier: verifier
                ).resolveDatabaseURL(
                    legacyCandidates: [legacyURL],
                    destinationURL: destinationURL,
                    markerKey: markerKey
                )
                XCTAssertEqual(resolved.standardizedFileURL, destinationURL.standardizedFileURL)
                XCTAssertTrue(defaults.bool(forKey: markerKey))
            }
        }
    }

    func testCompletedMarkerWithoutAnyStoreFailsInsteadOfCreatingBlankDatabase() throws {
        try withTemporaryMigration { legacyURL, destinationURL, defaults, markerKey in
            defaults.set(true, forKey: markerKey)

            XCTAssertThrowsError(
                try MlsProviderStoreMigrator(defaults: defaults).resolveDatabaseURL(
                    legacyCandidates: [legacyURL],
                    destinationURL: destinationURL,
                    markerKey: markerKey
                )
            ) { error in
                guard let migrationError = error as? MlsProviderStoreMigrator.MigrationError,
                      case .noUsableStore = migrationError else {
                    return XCTFail("Expected noUsableStore, received \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        }
    }

    func testMlsClientMigratesLegacyHashedStoreIntoApplicationSupportRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ermis-mls-client-migration-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("Documents", isDirectory: true)
        let applicationSupportRoot = root.appendingPathComponent("Application Support", isDirectory: true)
        let userId = "alice-\(UUID().uuidString)"
        let namespace = SHA256.hash(data: Data(userId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let dbName = "ermis_mls_\(namespace).db"
        let legacyURL = legacyRoot
            .appendingPathComponent("mls", isDirectory: true)
            .appendingPathComponent(dbName)
        let destinationURL = applicationSupportRoot
            .appendingPathComponent("mls", isDirectory: true)
            .appendingPathComponent(dbName)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try makeOpenMlsStore(at: legacyURL, userId: userId, groupIds: ["team:migrated"])

        let suite = "io.ermis.tests.mls-provider-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secureStore = DeviceIdSecureStore()
        let deviceIdStore = MlsDeviceIdStore(
            defaults: defaults,
            legacyDefaults: defaults,
            secureStore: secureStore
        )
        let client = MlsClient(
            storageFolderURL: applicationSupportRoot,
            legacyStorageFolderURLs: [legacyRoot],
            deviceIdStore: deviceIdStore,
            userDefaults: defaults
        )

        try client.setup(with: userId)

        XCTAssertEqual(try client.getStoredGroupIdList(), ["team:migrated"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        try client.purgeCurrentUserData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        // Explicit account purge clears the migration marker too, so the same account can create
        // a new empty provider instead of failing closed on a now-missing completed store.
        try client.setup(with: userId)
        XCTAssertEqual(try client.getStoredGroupIdList(), [])

        // A fresh destination is marked only after it opens successfully. If an older app later
        // recreates a legacy file, that stale store must not replace the authoritative provider.
        try client.reset()
        try makeOpenMlsStore(at: legacyURL, userId: userId, groupIds: ["team:stale"])
        try client.setup(with: userId)
        XCTAssertEqual(try client.getStoredGroupIdList(), [])
    }

    func testDefaultMlsRootUsesApplicationSupport() throws {
        let url = try XCTUnwrap(ErmisClientConfig.initMlsStorageFolderURL(groupIdentifier: nil))
        XCTAssertTrue(url.path.contains("Application Support"))
        XCTAssertEqual(url.lastPathComponent, "network.ermis.ermisChat")
    }

    private func withTemporaryMigration(
        _ body: (
            _ legacyURL: URL,
            _ destinationURL: URL,
            _ defaults: UserDefaults,
            _ markerKey: String
        ) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ermis-mls-migration-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "io.ermis.tests.mls-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(
            legacyDirectory.appendingPathComponent("legacy.db"),
            destinationDirectory.appendingPathComponent("destination.db"),
            defaults,
            "migration-complete"
        )
    }

    private func makeOpenMlsStore(
        at databaseURL: URL,
        userId: String,
        groupIds: [String]
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let provider = try Provider.newWithPath(dbPath: databaseURL.path)
        let identity = try Identity(provider: provider, userId: userId)
        try provider.storeIdentity(userId: userId, identityBytes: identity.toBytes())
        for groupId in groupIds {
            let group = try Group.createWithCid(
                provider: provider,
                founder: identity,
                cid: groupId
            )
            try group.saveState(provider: provider)
        }
    }
}
