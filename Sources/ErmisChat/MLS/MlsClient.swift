//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared
import open_mls_ios
import CryptoKit

struct MlsProcessedApplicationMessage {
    let plaintext: Data
    let payload: E2ePayload
    let aad: Data
    let epoch: UInt64
    let senderIndex: UInt32
    let resultingGroupEpoch: UInt64
}

struct MlsProcessedProtocolMetadata: Equatable {
    let messageEpoch: UInt64
    let senderIndex: UInt32
    let aad: Data
    let groupEpochBefore: UInt64
    let groupEpochAfter: UInt64
}

struct MlsRebootstrapCandidate {
    let providerPath: String
    let groupId: Data
    let epoch: UInt64
    let groupInfo: Data
    let ratchetTree: Data
    let welcome: Data?
}

struct MlsArchivedApplicationMessage {
    let plaintext: Data
    let payload: E2ePayload
    let aad: Data
    let epoch: UInt64
    let senderIndex: UInt32
    let senderGeneration: UInt32
    let ownMessage: Bool
}

enum MlsProcessedProtocolMessage: Equatable {
    case proposal(MlsProcessedProtocolMetadata)
    case commit(MlsProcessedProtocolMetadata)

    var metadata: MlsProcessedProtocolMetadata {
        switch self {
        case .proposal(let metadata), .commit(let metadata):
            return metadata
        }
    }
}

public class MlsClient {
    public static let deviceIdKey = MlsDeviceIdStore.deviceIdKey
    public static let cursorKey = "ermis_e2e_sync_cursor"

    var archiveCaptureHandler: ((String, UInt64, Group, String) -> Void)?
    private var archiveScopesByGroupId: [Data: (String, UInt64)] = [:]
    private func captureArchive(_ group: Group, role: String = "primary") {
        guard let scope = archiveScopesByGroupId[group.groupId()] else { return }
        archiveCaptureHandler?(scope.0, scope.1, group, role)
    }

    var provider: Provider?
    var identity: Identity?
    var userId: UserId?
    var hasSetup: Bool = false
    let userDefaults: UserDefaults
    let deviceIdStore: MlsDeviceIdStore
    private let storageFolderURL: URL?
    private let legacyStorageFolderURLs: [URL]
    private var providerDatabaseURL: URL?

    func membershipMutationStore() throws -> MlsMembershipMutationStore {
        guard userId != nil, let providerDatabaseURL else { throw ClientError.MlsNoProviderError() }
        return MlsMembershipMutationStore(root: providerDatabaseURL.appendingPathExtension("member-mutations"))
    }
    private var providerDatabaseCleanupURLs: [URL] = []
    private var currentProviderMigrationMarkerKey: String?
    private var mutationExecutorAssertion: (() -> Void)?
    private var generationProviders: [String: Provider] = [:]
    private var generationIdentities: [String: Identity] = [:]
    private var providerContextByGroupId: [Data: String] = [:]
    private var externalJoinCandidateContexts: [String: (group: Group, provider: Provider, identity: Identity)] = [:]
    private let generationMarkerPrefix = "ermis_mls_generation_v1:"
    private let historicalGenerationMarkerPrefix = "ermis_mls_generation_history_v1:"
    private let recoveryCheckpointLock = NSRecursiveLock()
    private let pendingGenerationJoinPrefix = "ermis_mls_generation_join_v1:"

    struct GroupGenerationMarker: Codable, Equatable {
        let cid: String
        let generation: UInt64
        let groupId: Data?
        let epoch: UInt64
        let status: String
        let operationId: String?
        let providerPath: String?
        var externalJoinBody: Data? = nil
        var candidateBaseMarker: Data? = nil
        var candidateBaseEpoch: UInt64? = nil
        var candidateFenceVersion: Int? = nil

        init(
            cid: String,
            generation: UInt64,
            groupId: Data?,
            epoch: UInt64,
            status: String,
            operationId: String?,
            providerPath: String? = nil
        ) {
            self.cid = cid
            self.generation = generation
            self.groupId = groupId
            self.epoch = epoch
            self.status = status
            self.operationId = operationId
            self.providerPath = providerPath
        }
    }

    /// Returns the device ID for the current userId, or nil if not available.
    var currentDeviceId: String? {
        guard let userId else { return nil }
        return deviceIdStore.canonicalDeviceId(for: userId, createIfNeeded: false)
    }

    init(
        storageFolderURL: URL? = nil,
        legacyStorageFolderURLs: [URL] = [],
        applicationGroupIdentifier: String? = nil,
        deviceIdStore: MlsDeviceIdStore? = nil,
        userDefaults: UserDefaults? = nil
    ) {
        self.storageFolderURL = storageFolderURL
        self.legacyStorageFolderURLs = legacyStorageFolderURLs
        self.userDefaults = userDefaults
            ?? applicationGroupIdentifier.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        self.deviceIdStore = deviceIdStore ?? MlsDeviceIdStore(defaults: self.userDefaults)
        if self.userDefaults !== UserDefaults.standard {
            Self.migrateLegacyDefaultsIfNeeded(to: self.userDefaults)
        }
        initLogger()
    }

    public func reset() throws {
        provider = nil
        identity = nil
        userId = nil
        hasSetup = false
        providerDatabaseURL = nil
        providerDatabaseCleanupURLs = []
        currentProviderMigrationMarkerKey = nil
        generationProviders = [:]
        generationIdentities = [:]
        providerContextByGroupId = [:]
        externalJoinCandidateContexts = [:]
    }

    public func setup(with userId: String) throws {
//        guard self.userId != userId || !hasSetup else {
//            generateDeviceIdIfNeeded(for: userId)
//            return
//        }
        
        
        // Releasing these references closes the SQLite provider before any cross-directory copy.
        provider = nil
        identity = nil
        hasSetup = false
        providerDatabaseURL = nil
        providerDatabaseCleanupURLs = []
        currentProviderMigrationMarkerKey = nil
        generationProviders = [:]
        generationIdentities = [:]
        providerContextByGroupId = [:]
        externalJoinCandidateContexts = [:]

        self.userId = userId
        generateDeviceIdIfNeeded(for: userId)
        guard let storageRoot = storageFolderURL ?? Self.defaultStorageFolderURL() else {
            throw CocoaError(.fileNoSuchFile)
        }

        let namespace = Self.storageNamespace(for: userId)
        let dbName = "ermis_mls_" + namespace + ".db"
        let destinationURL = storageRoot
            .appendingPathComponent("mls", isDirectory: true)
            .appendingPathComponent(dbName)
        let documentDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        var legacyRoots = legacyStorageFolderURLs
        if let documentDirectory {
            legacyRoots.append(documentDirectory)
        }
        let legacyCandidates = Self.legacyProviderCandidates(
            roots: legacyRoots,
            userId: userId,
            dbName: dbName,
            documentDirectory: documentDirectory
        )
        let markerKey = Self.providerMigrationMarkerKey(
            namespace: namespace,
            destinationURL: destinationURL
        )
        let migrator = MlsProviderStoreMigrator(defaults: userDefaults)
        let resolvedURL = try migrator.resolveDatabaseURL(
            legacyCandidates: legacyCandidates,
            destinationURL: destinationURL,
            markerKey: markerKey
        )
        if resolvedURL.standardizedFileURL != destinationURL.standardizedFileURL {
            log.warning(
                "MLS provider migration did not complete; continuing with verified legacy store"
            )
        }

        let provider = try Provider.newWithPath(dbPath: resolvedURL.path)
        if let identityBytes = try provider.loadIdentity() {
            self.identity = try Identity.fromBytes(provider: provider, data: identityBytes)
        } else {
            let identity = try Identity(provider: provider, userId: userId)
            self.identity = identity
            let identityBytes = try identity.toBytes()
            try provider.storeIdentity(userId: userId, identityBytes: identityBytes)
        }
        try migrator.protectResolvedStore(at: resolvedURL)
        if resolvedURL.standardizedFileURL == destinationURL.standardizedFileURL {
            // Fresh installs have no legacy store to migrate, but still need an authoritative
            // marker after the new provider has opened and its identity is durable. This prevents
            // a later stale legacy file from replacing a valid Application Support store.
            userDefaults.set(true, forKey: markerKey)
        }

        self.provider = provider
        providerDatabaseURL = resolvedURL
        providerDatabaseCleanupURLs = Self.uniqueURLs(
            [resolvedURL, destinationURL] + legacyCandidates
        )
        currentProviderMigrationMarkerKey = markerKey
        hasSetup = true
    }

    func purgeCurrentUserData() throws {
        assertMutationExecutor()
        guard let currentUserId = userId else { return }
        let namespace = Self.storageNamespace(for: currentUserId)
        let markerPrefixes = [generationMarkerPrefix, pendingGenerationJoinPrefix]
            .map { $0 + namespace + ":" }
            + ["ermis_mls_rebootstrap_checkpoint_v1:" + namespace + ":"]
        let markerKeys = userDefaults.dictionaryRepresentation().keys.filter { key in
            markerPrefixes.contains { key.hasPrefix($0) }
        }
        // Explicit purge also covers durable records after the preferences cache was lost.
        let recoveryDirectory = try recoveryCheckpointURL(key: "purge").deletingLastPathComponent()
        let recoveryFiles = FileManager.default.fileExists(atPath: recoveryDirectory.path)
            ? try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil) : []
        let recoveryData = try recoveryFiles.map { try Data(contentsOf: $0) }
        let markerData = markerKeys.compactMap { userDefaults.data(forKey: $0) } + recoveryData
        let generationDatabaseURLs = markerData.compactMap { data -> URL? in
            let markerPath = (try? JSONDecoder().decode(
                GroupGenerationMarker.self,
                from: data
            ))?.providerPath
            let checkpointPath = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }?["providerPath"] as? String
            guard let providerPath = markerPath ?? checkpointPath else { return nil }
            return URL(fileURLWithPath: providerPath)
        }
        let baseDatabaseURLs = providerDatabaseCleanupURLs.isEmpty
            ? [providerDatabaseURL].compactMap { $0 }
            : providerDatabaseCleanupURLs
        let databaseURLs = Self.uniqueURLs(baseDatabaseURLs + generationDatabaseURLs)
        let migrationMarkerKey = currentProviderMigrationMarkerKey
        if let provider {
            try provider.deleteAllGroups()
            try provider.deleteIdentity()
        }
        provider = nil
        identity = nil
        userId = nil
        hasSetup = false
        providerDatabaseURL = nil
        providerDatabaseCleanupURLs = []
        currentProviderMigrationMarkerKey = nil
        generationProviders = [:]
        generationIdentities = [:]
        providerContextByGroupId = [:]
        externalJoinCandidateContexts = [:]

        for databaseURL in databaseURLs {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        if FileManager.default.fileExists(atPath: recoveryDirectory.path) {
            try FileManager.default.removeItem(at: recoveryDirectory)
        }
        deviceIdStore.removeUser(currentUserId)
        removeUserScopedDefault(forKey: Self.cursorKey, userId: currentUserId)
        markerKeys.forEach(userDefaults.removeObject(forKey:))
        if let migrationMarkerKey {
            userDefaults.removeObject(forKey: migrationMarkerKey)
        }
    }

    /// Installs the repository-owned runtime guard after dependency construction. Direct
    /// `MlsClient` tests remain possible when no guard is installed; production group mutations
    /// assert in debug builds unless they are running on `MlsMutationExecutor`.
    func installMutationExecutorAssertion(_ assertion: @escaping () -> Void) {
        mutationExecutorAssertion = assertion
    }

    private func assertMutationExecutor() {
        mutationExecutorAssertion?()
    }

    private func removeUserScopedDefault(forKey key: String, userId: String) {
        var values = userDefaults.dictionary(forKey: key) ?? [:]
        values.removeValue(forKey: userId)
        userDefaults.set(values, forKey: key)
    }

    private static func storageNamespace(for userId: String) -> String {
        SHA256.hash(data: Data(userId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func providerMigrationMarkerKey(namespace: String, destinationURL: URL) -> String {
        let destinationNamespace = storageNamespace(
            for: destinationURL.standardizedFileURL.path
        )
        return "ermis_mls_provider_migration_v1_\(namespace)_\(destinationNamespace)"
    }

    private static func defaultStorageFolderURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("network.ermis.ermisChat", isDirectory: true)
    }

    private static func legacyProviderCandidates(
        roots: [URL],
        userId: String,
        dbName: String,
        documentDirectory: URL?
    ) -> [URL] {
        var candidates = roots.map {
            $0.appendingPathComponent("mls", isDirectory: true)
                .appendingPathComponent(dbName)
        }
        if let documentDirectory {
            candidates.append(
                documentDirectory.appendingPathComponent("ermis_mls_" + userId + ".db")
            )
        }
        return uniqueURLs(candidates)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }

    private static func migrateLegacyDefaultsIfNeeded(to destination: UserDefaults) {
        for key in [deviceIdKey, cursorKey, "ermis_mls_login_time", "ermis_e2e_removed_cursor"]
            where destination.object(forKey: key) == nil {
            if let value = UserDefaults.standard.object(forKey: key) {
                destination.set(value, forKey: key)
            }
        }
    }
    
    func getChannelId(projectId: String, userIds: [String]) -> String {
        hashChannelId(projectId: projectId, userIds: userIds)
    }

    private func createGroup(with cid: String) throws -> Group {
        assertMutationExecutor()
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }

        let group = try Group.createWithCid(provider: provider, founder: identity, cid: cid)
        archiveScopesByGroupId[group.groupId()] = (cid, 0)
        return group
    }

    private func generationContext(
        for marker: GroupGenerationMarker?
    ) throws -> (provider: Provider, identity: Identity) {
        guard let providerPath = marker?.providerPath else {
            guard let provider else { throw ClientError.MlsNoProviderError() }
            guard let identity else { throw ClientError.MlsNoIdentityError() }
            return (provider, identity)
        }
        if let provider = generationProviders[providerPath],
           let identity = generationIdentities[providerPath] {
            return (provider, identity)
        }
        let provider = try Provider.newWithPath(dbPath: providerPath)
        guard let identityBytes = try provider.loadIdentity() else {
            throw ClientError.MlsNoIdentityError()
        }
        let identity = try Identity.fromBytes(provider: provider, data: identityBytes)
        generationProviders[providerPath] = provider
        generationIdentities[providerPath] = identity
        return (provider, identity)
    }

    private func generationProvider(for marker: GroupGenerationMarker?) throws -> Provider {
        guard let providerPath = marker?.providerPath else {
            guard let provider else { throw ClientError.MlsNoProviderError() }
            return provider
        }
        if let provider = generationProviders[providerPath] {
            return provider
        }
        let provider = try Provider.newWithPath(dbPath: providerPath)
        generationProviders[providerPath] = provider
        return provider
    }

    private func generationContext(for group: Group) throws -> (provider: Provider, identity: Identity) {
        if let context = externalJoinCandidateContexts.values.first(where: { $0.group === group }) { return (context.provider, context.identity) }
        if let providerPath = providerContextByGroupId[group.groupId()] {
            return try generationContext(
                for: GroupGenerationMarker(
                    cid: "",
                    generation: 1,
                    groupId: group.groupId(),
                    epoch: group.epoch(),
                    status: "active",
                    operationId: nil,
                    providerPath: providerPath
                )
            )
        }
        return try generationContext(for: nil)
    }

    private func generationProvider(for group: Group) throws -> Provider {
        if let context = externalJoinCandidateContexts.values.first(where: { $0.group === group }) { return context.provider }
        if let providerPath = providerContextByGroupId[group.groupId()] {
            return try generationProvider(
                for: GroupGenerationMarker(
                    cid: "",
                    generation: 1,
                    groupId: group.groupId(),
                    epoch: group.epoch(),
                    status: "active",
                    operationId: nil,
                    providerPath: providerPath
                )
            )
        }
        return try generationProvider(for: nil)
    }

    func createGroup(cid: String, generation: UInt64, groupId: Data) throws -> Group {
        assertMutationExecutor()
        guard generation > 0, !groupId.isEmpty, groupId.count <= 255 else {
            throw ClientError.Unexpected("Invalid generation-aware MLS GroupId.")
        }
        guard let provider else { throw ClientError.MlsNoProviderError() }
        guard let identity else { throw ClientError.MlsNoIdentityError() }
        let group = try Group.createWithGroupId(provider: provider, founder: identity, groupId: groupId)
        archiveScopesByGroupId[group.groupId()] = (cid, generation)
        return group
    }

    func prepareRebootstrapCandidate(
        operationId: String,
        groupId: Data,
        keyPackages: [Data]
    ) throws -> MlsRebootstrapCandidate {
        assertMutationExecutor()
        guard UUID(uuidString: operationId) != nil,
              !groupId.isEmpty,
              groupId.count <= 255 else {
            throw ClientError.Unexpected("Invalid MLS rebootstrap candidate identity.")
        }
        guard let identity else { throw ClientError.MlsNoIdentityError() }
        guard let storageRoot = storageFolderURL ?? Self.defaultStorageFolderURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = storageRoot
            .appendingPathComponent("mls", isDirectory: true)
            .appendingPathComponent("rebootstrap", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent(operationId + ".db")
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ClientError.Unexpected("MLS rebootstrap candidate already exists.")
        }
        let candidateProvider = try Provider.newWithPath(dbPath: databaseURL.path)
        let identityBytes = try identity.toBytes()
        let candidateIdentity = try Identity.fromBytes(
            provider: candidateProvider,
            data: identityBytes
        )
        guard let userId else { throw ClientError.MlsNoIdentityError() }
        try candidateProvider.storeIdentity(userId: userId, identityBytes: identityBytes)
        let group = try Group.createWithGroupId(
            provider: candidateProvider,
            founder: candidateIdentity,
            groupId: groupId
        )
        var welcome: Data?
        if !keyPackages.isEmpty {
            let packages = try keyPackages.map { try KeyPackage.fromBytes(data: $0) }
            let bundle = try group.addMembers(
                provider: candidateProvider,
                sender: candidateIdentity,
                newMembers: packages
            )
            welcome = bundle.welcome
            guard welcome != nil else {
                throw ClientError.Unexpected("MLS bootstrap Add did not produce Welcome bytes.")
            }
            try group.mergePendingCommit(provider: candidateProvider)
        }
        try group.saveState(provider: candidateProvider)
        let groupInfo = try group.exportGroupInfo(
            provider: candidateProvider,
            sender: candidateIdentity,
            withRatchetTree: true
        )
        return MlsRebootstrapCandidate(
            providerPath: databaseURL.path,
            groupId: groupId,
            epoch: group.epoch(),
            groupInfo: groupInfo,
            ratchetTree: group.exportRatchetTree().toBytes(),
            welcome: welcome
        )
    }

    func removeRebootstrapCandidate(at providerPath: String) throws {
        let candidateURL = URL(fileURLWithPath: providerPath).standardizedFileURL
        guard candidateURL.lastPathComponent.hasSuffix(".db"),
              candidateURL.deletingLastPathComponent().lastPathComponent == "rebootstrap" else {
            throw ClientError.Unexpected("Refusing to remove an untrusted candidate path.")
        }
        generationProviders.removeValue(forKey: providerPath)
        generationIdentities.removeValue(forKey: providerPath)
        providerContextByGroupId = providerContextByGroupId.filter { $0.value != providerPath }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: candidateURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func activateRebootstrapCandidate(
        cid: String,
        generation: UInt64,
        operationId: String,
        candidate: MlsRebootstrapCandidate
    ) throws {
        let marker = GroupGenerationMarker(
            cid: cid,
            generation: generation,
            groupId: candidate.groupId,
            epoch: candidate.epoch,
            status: "active",
            operationId: operationId,
            providerPath: candidate.providerPath
        )
        let context = try generationContext(for: marker)
        let group = try Group.loadFromStorageWithGroupId(
            provider: context.provider,
            groupId: candidate.groupId
        )
        guard group.epoch() == candidate.epoch, group.isOperational() else {
            throw ClientError.Unexpected("Activated MLS rebootstrap candidate is not usable.")
        }
        providerContextByGroupId[candidate.groupId] = candidate.providerPath
        try saveGenerationMarker(marker)
    }

    func loadGroup(with cid: String) throws -> Group {
        let pending = loadPendingGenerationJoin(cid: cid)
        // DEC084 candidates are private staging state until canonical receipt activation.
        let marker = pending?.candidateFenceVersion == 1 ? loadGenerationMarker(cid: cid) : (pending ?? loadGenerationMarker(cid: cid))
        if marker?.status == "checkpoint_corrupt" { throw ClientError("MLS recovery checkpoint is corrupt") }
        let context = try generationContext(for: marker)
        let group: Group
        if let marker, marker.generation > 0, let groupId = marker.groupId {
            group = try Group.loadFromStorageWithGroupId(provider: context.provider, groupId: groupId)
            if let providerPath = marker.providerPath {
                providerContextByGroupId[groupId] = providerPath
            }
        } else {
            group = try Group.loadFromStorage(provider: context.provider, cid: cid)
        }
        if let providerPath = marker?.providerPath {
            providerContextByGroupId[group.groupId()] = providerPath
        } else {
            providerContextByGroupId.removeValue(forKey: group.groupId())
        }
        archiveScopesByGroupId[group.groupId()] = (cid, marker?.generation ?? 0)
        return group
    }

    func loadGroup(cid: String, generation: UInt64, groupId: Data) throws -> Group {
        guard let marker = loadGenerationMarker(cid: cid),
              marker.generation == generation,
              marker.groupId == groupId else {
            throw ClientError.Unexpected("MLS generation marker does not match authoritative GroupId.")
        }
        let context = try generationContext(for: marker)
        let group = try Group.loadFromStorageWithGroupId(provider: context.provider, groupId: groupId)
        if let providerPath = marker.providerPath {
            providerContextByGroupId[groupId] = providerPath
        }
        return group
    }

    private func recoveryCheckpointURL(key: String) throws -> URL {
        guard let userId, let database = providerDatabaseURL else { throw ClientError.MlsNoProviderError() }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return database.deletingLastPathComponent().appendingPathComponent("recovery-checkpoints", isDirectory: true)
            .appendingPathComponent(Self.storageNamespace(for: userId), isDirectory: true).appendingPathComponent(name + ".json")
    }

    func readRecoveryCheckpoint(key: String) throws -> Data? {
        recoveryCheckpointLock.lock(); defer { recoveryCheckpointLock.unlock() }
        let url = try recoveryCheckpointURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeRecoveryCheckpoint(_ data: Data, key: String) throws {
        recoveryCheckpointLock.lock(); defer { recoveryCheckpointLock.unlock() }
        let url = try recoveryCheckpointURL(key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
        guard try Data(contentsOf: url) == data else { throw ClientError("Recovery checkpoint readback failed") }
    }

    private func corruptGenerationCheckpoint(cid: String) -> GroupGenerationMarker {
        var marker = GroupGenerationMarker(cid: cid, generation: 0, groupId: nil, epoch: 0,
            status: "checkpoint_corrupt", operationId: nil)
        marker.candidateFenceVersion = 1
        return marker // Retain corrupt bytes and fail closed; never infer absence/new intent.
    }

    private func readGenerationCheckpoint(cid: String, key: String) -> GroupGenerationMarker? {
        do {
            let data = try readRecoveryCheckpoint(key: key) ?? userDefaults.data(forKey: key)
            guard let data else { return nil }
            return try JSONDecoder().decode(GroupGenerationMarker.self, from: data)
        } catch { return corruptGenerationCheckpoint(cid: cid) }
    }

    func loadGenerationMarker(cid: String) -> GroupGenerationMarker? {
        guard let key = generationMarkerKey(prefix: generationMarkerPrefix, cid: cid) else { return nil }
        return readGenerationCheckpoint(cid: cid, key: key)
    }

    func loadGenerationMarker(cid: String, generation: UInt64) -> GroupGenerationMarker? {
        guard let key = historicalGenerationMarkerKey(cid: cid, generation: generation) else { return nil }
        if let marker = readGenerationCheckpoint(cid: cid, key: key) { return marker }
        let current = loadGenerationMarker(cid: cid)
        return current?.generation == generation ? current : nil
    }

    func saveGenerationMarker(_ marker: GroupGenerationMarker) throws {
        recoveryCheckpointLock.lock(); defer { recoveryCheckpointLock.unlock() }
        guard let key = generationMarkerKey(prefix: generationMarkerPrefix, cid: marker.cid),
              let historicalKey = historicalGenerationMarkerKey(cid: marker.cid, generation: marker.generation) else {
            throw ClientError.MlsNoIdentityError()
        }
        let encoded = try JSONEncoder().encode(marker)
        try writeRecoveryCheckpoint(encoded, key: historicalKey)
        try writeRecoveryCheckpoint(encoded, key: key)
        userDefaults.set(encoded, forKey: key); userDefaults.set(encoded, forKey: historicalKey)
        if let groupId = marker.groupId { archiveScopesByGroupId[groupId] = (marker.cid, marker.generation) }
    }

    func loadPendingGenerationJoin(cid: String) -> GroupGenerationMarker? {
        guard let key = generationMarkerKey(prefix: pendingGenerationJoinPrefix, cid: cid) else { return nil }
        return readGenerationCheckpoint(cid: cid, key: key)
    }

    func savePendingGenerationJoin(_ marker: GroupGenerationMarker) throws {
        recoveryCheckpointLock.lock(); defer { recoveryCheckpointLock.unlock() }
        guard let key = generationMarkerKey(prefix: pendingGenerationJoinPrefix, cid: marker.cid) else {
            throw ClientError.MlsNoIdentityError()
        }
        let encoded = try JSONEncoder().encode(marker)
        try writeRecoveryCheckpoint(encoded, key: key)
        userDefaults.set(encoded, forKey: key)
    }

    @discardableResult func removePendingGenerationJoin(cid: String, expected: GroupGenerationMarker? = nil) -> Bool {
        recoveryCheckpointLock.lock(); defer { recoveryCheckpointLock.unlock() }
        if let expected, loadPendingGenerationJoin(cid: cid) != expected { return false }
        guard let key = generationMarkerKey(prefix: pendingGenerationJoinPrefix, cid: cid) else { return false }
        do {
            let url = try recoveryCheckpointURL(key: key)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { return false }
        externalJoinCandidateContexts.removeValue(forKey: cid)
        userDefaults.removeObject(forKey: key)
        return true
    }

    private func generationMarkerKey(prefix: String, cid: String) -> String? {
        guard let userId else { return nil }
        return prefix + Self.storageNamespace(for: userId) + ":" + cid
    }

    private func historicalGenerationMarkerKey(cid: String, generation: UInt64) -> String? {
        guard let userId else { return nil }
        return historicalGenerationMarkerPrefix
            + Self.storageNamespace(for: userId)
            + ":"
            + cid
            + ":"
            + String(generation)
    }

    func isGroupLoaded(cid: String) -> Bool {
        (try? loadGroup(with: cid)) != nil
    }

    /// A retained group can still load after a commit evicts this device. It cannot
    /// encrypt or decrypt current application messages, even when its epoch is current.
    /// A local pending commit is transient and must finish through its normal receipt.
    func hasNonOperationalGroup(cid: String) -> Bool {
        guard let group = try? loadGroup(with: cid) else { return false }
        return !group.isOperational() && !group.hasPendingCommit()
    }

    func loadOrCreateGroup(with cid: String) throws -> Group {
        do {
            let group = try loadGroup(with: cid)
            return group
        } catch let error {
            guard let error = error as? MlsError else {
                throw error
            }
            switch error {
            case .GroupNotFound(let message):
                let group = try createGroup(with: cid)
                return group
            default:
                throw error
            }
        }
    }
    
    func getStoredGroupIdList() throws -> [String] {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        
        return try provider.storedGroupIds()
    }
    
    

    func addMember(to group: Group, memberKeyPackages: [KeyPackage]) throws -> CommitBundle {
        assertMutationExecutor()
        let (provider, identity) = try generationContext(for: group)
        
        if group.hasPendingCommit() {
            throw ClientError.Unexpected("MLS mutation pending; reconcile server ACK before retry")
        }
        log.debug("TTTTT AAAA BEFORE ADD MEMBER, EPOCH: \(group.epoch())")
        let commitBunddle = try group.addMembers(provider: provider, sender: identity, newMembers: memberKeyPackages)
        try group.saveState(provider: provider)
        log.debug("TTTTT AAAA AFTER ADD MEMBER, EPOCH: \(group.epoch())")
        return commitBunddle
    }

    func removeMember(_ userId: String, in group: Group) throws -> CommitBundle {
        assertMutationExecutor()
        let (provider, identity) = try generationContext(for: group)
        let commitBundle = try group.removeUser(provider: provider, sender: identity, userId: userId)
        return commitBundle
    }

    func removeMembers(_ userIds: [String], in group: Group) throws -> CommitBundle {
        assertMutationExecutor()
        let (provider, identity) = try generationContext(for: group)
        traceRemovalLeaves(userIds, group: group)
        log.debug("TTTTT AAAA BEFORE REMOVE USER, EPOCH: \(group.epoch())")
        let commitBundle = try group.removeUsers(provider: provider, sender: identity, userIds: userIds)
        try group.saveState(provider: provider)
        log.debug("TTTTT AAAA AFTER REMOVE USER, EPOCH: \(group.epoch())")
        return commitBundle
    }

    func keyPackageWorkStore(origin: String) throws -> MlsKeyPackageWorkStore {
        assertMutationExecutor()
        guard let userId, let currentDeviceId, let identity, let provider, let providerDatabaseURL,
              try provider.loadIdentity() == identity.toBytes() else { throw ClientError.MlsNoIdentityError() }
        let signer = identity.signaturePublicKey().base64EncodedString()
        return MlsKeyPackageWorkStore(root: providerDatabaseURL.appendingPathExtension("key-package-work"), scope: [origin, userId, currentDeviceId, signer].joined(separator: "|"))
    }
    func probeKeyPackageOwnership(_ refs: [Data]) throws -> [Bool] {
        assertMutationExecutor()
        guard let identity, let provider, try provider.loadIdentity() == identity.toBytes() else { throw ClientError.MlsNoIdentityError() }
        return try refs.map { ref in
            guard ref.count == 32 else { throw ClientError.Unexpected("key_package_reference_invalid") }
            return try identity.ownsKeyPackageRef(provider: provider, reference: ref)
        }
    }
    func generateKeyPackageBatch(count: Int) throws -> [(Data, Data)] {
        assertMutationExecutor()
        guard (1...100).contains(count), let identity, let provider else { throw ClientError.MlsNoIdentityError() }
        return try identity.keyPackages(provider: provider, count: UInt32(count)).map { (try $0.toBytes(), try $0.hashRef(provider: provider)) }
    }

    func keyPackageUploadProviderId() throws -> String {
        assertMutationExecutor()
        guard let identity, let provider, try provider.loadIdentity() == identity.toBytes() else { throw ClientError.MlsNoIdentityError() }
        return try provider.keyPackageUploadProviderId()
    }

    func prepareKeyPackageUpload(id: String, scope: String, nativeProviderId: String, count: Int) throws -> [(Data, Data)] {
        assertMutationExecutor()
        guard (1...100).contains(count), let identity, let provider, try provider.loadIdentity() == identity.toBytes() else { throw ClientError.MlsNoIdentityError() }
        let scopeHash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let bytes = try identity.prepareKeyPackageUpload(provider: provider, operationId: id, scope: scopeHash, expectedProviderId: nativeProviderId, count: UInt32(count))
        guard bytes.count == count, bytes.allSatisfy({ validateKeyPackageBytes(data: $0) }) else { throw MlsKeyPackageBatchInvalid() }
        return try bytes.map { ($0, try KeyPackage.fromBytes(data: $0).hashRef(provider: provider)) }
    }

    func recoverKeyPackageUpload(id: String, scope: String) throws -> [(Data, Data)]? {
        assertMutationExecutor()
        guard let identity, let provider, try provider.loadIdentity() == identity.toBytes() else { throw ClientError.MlsNoIdentityError() }
        let scopeHash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let bytes = try identity.recoverKeyPackageUpload(provider: provider, operationId: id, scope: scopeHash) else { return nil }
        guard (1...100).contains(bytes.count), bytes.allSatisfy({ validateKeyPackageBytes(data: $0) }) else { throw MlsKeyPackageBatchInvalid() }
        return try bytes.map { ($0, try KeyPackage.fromBytes(data: $0).hashRef(provider: provider)) }
    }

    func getKeyPackage() -> Data? {
        assertMutationExecutor()
        guard let provider else {
            return nil
        }
        guard let identity else {
            return nil
        }
        guard let keyPackage = try? identity.keyPackage(provider: provider) else { return nil }
        return try? keyPackage.toBytes()
    }

    func getKeyPackage(count: Int) throws -> [Data] {
        assertMutationExecutor()
        guard (1...100).contains(count) else {
            throw ClientError.Unexpected("MLS KeyPackage count must be between 1 and 100.")
        }
        guard let provider else { throw ClientError.MlsNoProviderError() }
        guard let identity else { throw ClientError.MlsNoIdentityError() }
        let keyPackages = try identity.keyPackages(provider: provider, count: UInt32(count))
        return try keyPackages.map { try $0.toBytes() }
    }

    func encrypt(
        inputData: Data,
        in group: Group,
        trace: E2eeSendTrace.Context? = nil
    ) throws -> Data {
        assertMutationExecutor()
        let provider: Provider
        let identity: Identity
        do {
            (provider, identity) = try generationContext(for: group)
        } catch {
            trace?.failure(stage: "mls_precondition_failed", error: error)
            throw error
        }

        let epoch = UInt64(group.epoch())
        log.info(
            "mls_group_health stage=before_create epoch=\(epoch) operational=\(group.isOperational()) "
                + "pending_commit=\(group.hasPendingCommit()) member_count=\(group.members().count) "
                + "self_member_count=\(userId.map { group.membersByUserId(userId: $0).count } ?? -1)",
            subsystems: .mls
        )
        let createStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(
            stage: "mls_create_started",
            epoch: epoch,
            payloadBytes: inputData.count,
            authenticatedAAD: false
        )
        let encryptedData: Data
        do {
            captureArchive(group)
            encryptedData = try group.createMessage(
                provider: provider,
                sender: identity,
                plaintext: inputData
            )
        } catch {
            trace?.failure(
                stage: "mls_create_failed",
                error: error,
                epoch: epoch,
                operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: createStartedAt)
            )
            throw error
        }
        trace?.info(
            stage: "mls_create_succeeded",
            epoch: epoch,
            ciphertextBytes: encryptedData.count,
            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: createStartedAt),
            authenticatedAAD: false
        )

        let saveStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(stage: "mls_state_save_started", epoch: epoch)
        do {
            try group.saveState(provider: provider)
        captureArchive(group)
        } catch {
            trace?.failure(
                stage: "mls_state_save_failed",
                error: error,
                epoch: epoch,
                operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: saveStartedAt)
            )
            throw error
        }
        trace?.info(
            stage: "mls_state_save_succeeded",
            epoch: epoch,
            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: saveStartedAt)
        )
        return encryptedData
    }

    func encrypt(
        inputData: Data,
        aad: Data,
        in group: Group,
        trace: E2eeSendTrace.Context? = nil
    ) throws -> Data {
        assertMutationExecutor()
        let provider: Provider
        let identity: Identity
        do {
            (provider, identity) = try generationContext(for: group)
        } catch {
            trace?.failure(stage: "mls_precondition_failed", error: error)
            throw error
        }

        let epoch = UInt64(group.epoch())
        let createStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(
            stage: "mls_create_started",
            epoch: epoch,
            payloadBytes: inputData.count,
            authenticatedAAD: true
        )
        let encryptedData: Data
        do {
            captureArchive(group)
            encryptedData = try group.createMessageWithAad(
                provider: provider,
                sender: identity,
                plaintext: inputData,
                aad: aad
            )
        } catch {
            trace?.failure(
                stage: "mls_create_failed",
                error: error,
                epoch: epoch,
                operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: createStartedAt)
            )
            throw error
        }
        trace?.info(
            stage: "mls_create_succeeded",
            epoch: epoch,
            ciphertextBytes: encryptedData.count,
            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: createStartedAt),
            authenticatedAAD: true
        )

        let saveStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(stage: "mls_state_save_started", epoch: epoch)
        do {
            try group.saveState(provider: provider)
        captureArchive(group)
        } catch {
            trace?.failure(
                stage: "mls_state_save_failed",
                error: error,
                epoch: epoch,
                operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: saveStartedAt)
            )
            throw error
        }
        trace?.info(
            stage: "mls_state_save_succeeded",
            epoch: epoch,
            operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: saveStartedAt)
        )
        return encryptedData
    }

    func mergePendingCommit(in cid: ChannelId) throws {
        assertMutationExecutor()
        let group = try loadGroup(with: cid.rawValue)
        let provider = try generationProvider(for: group)
        captureArchive(group)
        try group.mergePendingCommit(provider: provider)
        try group.saveState(provider: provider)
        captureArchive(group)
    }

    func clearPendingCommit(in cid: ChannelId) throws {
        assertMutationExecutor()
        let group = try loadGroup(with: cid.rawValue)
        let provider = try generationProvider(for: group)
        try group.clearPendingCommit(provider: provider)
        try group.saveState(provider: provider)
    }

    func commitPendingProposal(in cid: ChannelId) throws {
        assertMutationExecutor()
        let group = try loadGroup(with: cid.rawValue)
        let (provider, identity) = try generationContext(for: group)
        try group.commitPendingProposals(provider: provider, sender: identity)
    }

    func clearPendingProposal(in cid: ChannelId) throws {
        assertMutationExecutor()
        let group = try loadGroup(with: cid.rawValue)
        let provider = try generationProvider(for: group)
        try group.clearPendingProposals(provider: provider)
    }

    func exportGroupInfo(of group: Group, withRatchetTree: Bool = true) throws -> Data {
        let (provider, identity) = try generationContext(for: group)
        return try group.exportGroupInfo(provider: provider, sender: identity, withRatchetTree: true)
    }

    func exportEpochArchive(of group: Group) throws -> ExportedEpochArchiveV2 {
        try group.archiveEpochV2()
    }

    func decryptArchivedApplication(
        cid: String,
        generation: UInt64,
        archive: Data,
        snapshot: Data,
        ciphertext: Data,
        allowOwnMessages: Bool = false,
        maxForwardDistance: UInt32 = 0
    ) throws -> MlsArchivedApplicationMessage {
        guard generation == 0 || loadGenerationMarker(cid: cid, generation: generation) != nil else {
            throw ClientError.Unexpected("Missing trusted MLS generation mapping for archive restore.")
        }
        let marker = generation == 0 ? nil : loadGenerationMarker(cid: cid, generation: generation)
        let provider = try generationProvider(for: marker)
        let archived = try decryptEpochArchiveV2(
            provider: provider,
            archive: archive,
            snapshot: snapshot,
            ciphertext: ciphertext,
            allowOwnMessages: allowOwnMessages,
            maxForwardDistance: maxForwardDistance
        )
        guard archived.content.count <= 16 * 1024 * 1024 else { throw E2eeArchiveError.invalidData }
        let payload = try JSONDecoder().decode(E2ePayload.self, from: archived.content)
        return MlsArchivedApplicationMessage(
            plaintext: archived.content,
            payload: payload,
            aad: archived.aad,
            epoch: archived.epoch,
            senderIndex: archived.senderIndex,
            senderGeneration: archived.generation,
            ownMessage: archived.ownMessage
        )
    }

    func encrypt(data: Data, in group: Group) throws -> Data {
        assertMutationExecutor()
        let (provider, identity) = try generationContext(for: group)
        captureArchive(group)
        let encryptedData = try group.createMessage(provider: provider, sender: identity, plaintext: data)
        try group.saveState(provider: provider)
        captureArchive(group)
        return encryptedData
    }

    /// Read retained history without advancing either the historical ratchet or
    /// current provider. A disposable loaded Group owns deferred in-memory secrets.
    func processRetainedHistoricalApplication(data: Data, cid: String, generation: UInt64) throws -> MlsProcessedApplicationMessage {
        assertMutationExecutor()
        guard let current = loadGenerationMarker(cid: cid), current.status == "active",
              generation < current.generation else { throw ClientError.Unexpected("Historical MLS scope is not retained.") }
        let historical = loadGenerationMarker(cid: cid, generation: generation)
        let context: Provider
        let group: Group
        if let historical {
            guard historical.cid == cid, historical.generation == generation, historical.status == "active",
                  let groupId = historical.groupId, groupId != current.groupId else {
                throw ClientError.Unexpected("Historical MLS checkpoint is uncertain.")
            }
            context = try generationProvider(for: historical)
            group = try Group.loadFromStorageWithGroupId(provider: context, groupId: groupId)
        } else {
            // Legacy generation zero predates generation markers. Its CID-bound
            // group remains in the original native database after new GroupId install.
            guard generation == 0, let provider else { throw ClientError.MlsNoProviderError() }
            context = provider
            group = try Group.loadFromStorage(provider: context, cid: cid)
            guard group.groupId() != current.groupId else { throw ClientError.Unexpected("Historical MLS group aliases current generation.") }
        }
        let processed = try group.processMessageDeferred(provider: context, msg: data)
        guard processed.messageType == .applicationMessage, let content = processed.content else {
            throw ClientError.Unexpected("Expected retained MLS application message.")
        }
        return MlsProcessedApplicationMessage(plaintext: content, payload: try JSONDecoder().decode(E2ePayload.self, from: content),
            aad: processed.aad, epoch: processed.epoch, senderIndex: processed.senderIndex, resultingGroupEpoch: group.epoch())
    }

    func processApplicationMessage(data: Data, in group: Group) throws -> MlsProcessedApplicationMessage {
        assertMutationExecutor()
        let provider = try generationProvider(for: group)
        captureArchive(group)
        let processedMessage = try group.processMessageDeferred(provider: provider, msg: data)
        guard processedMessage.messageType == .applicationMessage else {
            throw ClientError.Unexpected("Expected an MLS application message.")
        }
        guard let content = processedMessage.content else {
            throw ClientError.Unexpected("Decrypt messsage failed: content not found.")
        }
        let e2ePayload = try JSONDecoder().decode(E2ePayload.self, from: content)
        return MlsProcessedApplicationMessage(
            plaintext: content,
            payload: e2ePayload,
            aad: processedMessage.aad,
            epoch: processedMessage.epoch,
            senderIndex: processedMessage.senderIndex,
            resultingGroupEpoch: group.epoch()
        )
    }

    func saveState(of group: Group) throws {
        assertMutationExecutor()
        let provider = try generationProvider(for: group)
        try group.saveState(provider: provider)
        captureArchive(group)
    }

    /// Processes an MLS protocol message and preserves its type plus before/after epoch metadata.
    /// Commit callers write the durable event proof before this call, validate the returned epoch,
    /// and then explicitly store the complete group with `saveState(of:)`.
    func processProtocolMessage(data: Data, in group: Group) throws -> MlsProcessedProtocolMessage {
        assertMutationExecutor()
        let provider = try generationProvider(for: group)
        let epochBefore = group.epoch()
        captureArchive(group, role: "backup")
        let processedMessage = try group.processMessage(provider: provider, msg: data)
        return try protocolMessageResult(
            processedMessage,
            group: group,
            epochBefore: epochBefore
        )
    }

    /// Processes a durable protocol event at the Delivery Service timestamp bound to its
    /// persisted envelope. Historical callers must not substitute the receiver wall clock.
    func processProtocolMessage(
        data: Data,
        in group: Group,
        serverAcceptedAt: Date
    ) throws -> MlsProcessedProtocolMessage {
        assertMutationExecutor()
        let provider = try generationProvider(for: group)
        let acceptedAtSeconds = serverAcceptedAt.timeIntervalSince1970.rounded(.down)
        guard acceptedAtSeconds.isFinite,
              acceptedAtSeconds >= 0,
              acceptedAtSeconds <= Double(UInt64.max) else {
            throw ClientError.Unexpected("Invalid historical MLS acceptance timestamp.")
        }
        let epochBefore = group.epoch()
        captureArchive(group, role: "backup")
        let processedMessage = try group.processMessageAt(
            provider: provider,
            msg: data,
            serverAcceptedAtSeconds: UInt64(acceptedAtSeconds)
        )
        return try protocolMessageResult(
            processedMessage,
            group: group,
            epochBefore: epochBefore
        )
    }

    private func protocolMessageResult(
        _ processedMessage: ProcessedMessage,
        group: Group,
        epochBefore: UInt64
    ) throws -> MlsProcessedProtocolMessage {
        let metadata = MlsProcessedProtocolMetadata(
            messageEpoch: processedMessage.epoch,
            senderIndex: processedMessage.senderIndex,
            aad: processedMessage.aad,
            groupEpochBefore: epochBefore,
            groupEpochAfter: group.epoch()
        )
        switch processedMessage.messageType {
        case .proposal:
            return .proposal(metadata)
        case .commit:
            return .commit(metadata)
        case .applicationMessage:
            throw ClientError.Unexpected("Expected an MLS protocol message.")
        }
    }

    @discardableResult
    func joinWithWelcome(
        cid: String,
        welcome: Data,
        ratchetTree: RatchetTree,
        generation: UInt64 = 0,
        groupId: Data? = nil
    ) throws -> Group {
        assertMutationExecutor()
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        log.debug("[MLS] Join with welcome", subsystems: .mls)
        let group = try Group.joinWithWelcome(provider: provider, welcome: welcome, ratchetTree: ratchetTree)
        if generation > 0 {
            guard let groupId, group.groupId() == groupId else {
                throw ClientError.Unexpected("Welcome GroupId does not match authoritative generation.")
            }
            try saveGenerationMarker(
                GroupGenerationMarker(
                    cid: cid,
                    generation: generation,
                    groupId: groupId,
                    epoch: group.epoch(),
                    status: "active",
                    operationId: nil
                )
            )
        }
        archiveScopesByGroupId[group.groupId()] = (cid, generation)
        captureArchive(group)
        return group
    }

    func ownsDeviceId(_ deviceId: String, userId: UserId) -> Bool {
        deviceIdStore.owns(deviceId: deviceId, for: userId)
    }

    func externalJoin(groupInfo: Data, expectedGroupId: Data? = nil) throws -> ExternalJoinResult {
        assertMutationExecutor()
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let externalJoinResult = try joinExternal(provider: provider, identity: identity, groupInfo: groupInfo, ratchetTree: nil)
        if let expectedGroupId, externalJoinResult.group.groupId() != expectedGroupId {
            throw ClientError.Unexpected(
                "External-join GroupId does not match authoritative generation."
            )
        }
        return externalJoinResult
    }

    func externalJoinIsolated(cid: String, generation: UInt64, groupInfo: Data, expectedGroupId: Data?) throws -> ExternalJoinResult {
        assertMutationExecutor()
        guard provider != nil, let identity, let userId, let providerDatabaseURL else {
            throw ClientError.MlsNoIdentityError()
        }
        guard loadPendingGenerationJoin(cid: cid) == nil else { throw ClientError("External join outcome pending") }
        let baseMarker = try JSONEncoder().encode(loadGenerationMarker(cid: cid))
        let baseEpoch = activeGroupEpoch(cid: cid)
        let root = providerDatabaseURL.deletingLastPathComponent().appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(UUID().uuidString + ".db").path
        let candidate = try Provider.newWithPath(dbPath: path)
        let identityBytes = try identity.toBytes()
        let candidateIdentity = try Identity.fromBytes(provider: candidate, data: identityBytes)
        try candidate.storeIdentity(userId: userId, identityBytes: identityBytes)
        let result = try joinExternal(provider: candidate, identity: candidateIdentity, groupInfo: groupInfo, ratchetTree: nil)
        if let expectedGroupId, result.group.groupId() != expectedGroupId {
            throw ClientError.Unexpected("External recovery group identity mismatch.")
        }
        if result.group.hasPendingCommit() { try result.group.mergePendingCommit(provider: candidate) }
        try result.group.saveState(provider: candidate)
        generationProviders[path] = candidate
        generationIdentities[path] = candidateIdentity
        externalJoinCandidateContexts[cid] = (result.group, candidate, candidateIdentity)
        var checkpoint = GroupGenerationMarker(cid: cid, generation: generation,
            groupId: result.group.groupId(), epoch: result.group.epoch(), status: "external_join_prepared",
            operationId: nil, providerPath: path)
        checkpoint.candidateBaseMarker = baseMarker
        checkpoint.candidateBaseEpoch = baseEpoch
        checkpoint.candidateFenceVersion = 1
        try savePendingGenerationJoin(checkpoint)
        return result
    }

    private func activeGroupEpoch(cid: String) -> UInt64? {
        guard let context = try? generationContext(for: loadGenerationMarker(cid: cid)) else { return nil }
        let group: Group?
        if let marker = loadGenerationMarker(cid: cid), let id = marker.groupId {
            group = try? Group.loadFromStorageWithGroupId(provider: context.provider, groupId: id)
        } else { group = try? Group.loadFromStorage(provider: context.provider, cid: cid) }
        return group?.epoch()
    }

    func assertExternalJoinCandidateCurrent(cid: String) throws {
        assertMutationExecutor()
        guard let pending = loadPendingGenerationJoin(cid: cid), pending.candidateFenceVersion == 1,
            let bytes = pending.candidateBaseMarker else { throw ClientError.Unexpected("External join candidate fence missing") }
        if let active = loadGenerationMarker(cid: cid), active.providerPath == pending.providerPath,
            active.providerPath != nil, active.groupId == pending.groupId, active.generation == pending.generation,
            active.epoch == pending.epoch { return } // Restart after our accepted activation, before receipt retirement.
        let base = try JSONDecoder().decode(GroupGenerationMarker?.self, from: bytes)
        guard base == loadGenerationMarker(cid: cid), pending.candidateBaseEpoch == activeGroupEpoch(cid: cid) else {
            throw ClientError.Unexpected("External join candidate was superseded by Welcome or active state")
        }
    }

    func activateExternalJoinCandidate(cid: String, expected: GroupGenerationMarker, group: Group) throws {
        assertMutationExecutor()
        guard loadPendingGenerationJoin(cid: cid) == expected else { throw ClientError.Unexpected("External join candidate changed") }
        try assertExternalJoinCandidateCurrent(cid: cid)
        guard group.groupId() == expected.groupId, group.epoch() == expected.epoch, group.isOperational() else {
            throw ClientError.Unexpected("External join candidate is not operational")
        }
        try saveGenerationMarker(.init(cid: cid, generation: expected.generation, groupId: expected.groupId,
            epoch: expected.epoch, status: "active", operationId: nil, providerPath: expected.providerPath))
        if let path = expected.providerPath { providerContextByGroupId[group.groupId()] = path }
    }

    func finishExternalJoinCandidate(cid: String, expected: GroupGenerationMarker) throws {
        assertMutationExecutor()
        guard loadPendingGenerationJoin(cid: cid) == expected else { throw ClientError.Unexpected("External join candidate changed") }
        try assertExternalJoinCandidateCurrent(cid: cid)
        guard removePendingGenerationJoin(cid: cid, expected: expected) else { throw ClientError("External join checkpoint retirement failed") }
    }

    func resumeExternalJoinCandidate(cid: String) throws -> ExternalJoinResult? {
        assertMutationExecutor()
        guard let marker = loadPendingGenerationJoin(cid: cid), let body = marker.externalJoinBody,
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let encoded = json["commit"] as? String, let commit = Data(base64Encoded: encoded),
            let groupId = marker.groupId else { return nil }
        let context = try generationContext(for: marker)
        let group = try Group.loadFromStorageWithGroupId(provider: context.provider, groupId: groupId)
        externalJoinCandidateContexts[cid] = (group, context.provider, context.identity)
        return ExternalJoinResult(group: group, commit: commit)
    }

    func generateDeviceIdIfNeeded(for userId: String) {
        _ = deviceIdStore.canonicalDeviceId(for: userId)
    }
    
    func deleteGroup(cid: String) throws {
        assertMutationExecutor()
        do {
            let group = try loadGroup(with: cid)
            let provider = try generationProvider(for: group)
            try group.deleteState(provider: provider)
        } catch let error as MlsError {
            if case .GroupNotFound = error {
                return
            }
            throw error
        }
    }
    
    func deleteMessage(messageId: String) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        
    }
    
    func addMembersWithRemovals(in cid: String, removeUserIds: [String], addMembers: [KeyPackage]) throws -> (CommitBundle, RatchetTree, Int) {
        assertMutationExecutor()
        let group = try loadGroup(with: cid)
        let (provider, identity) = try generationContext(for: group)
        if group.hasPendingCommit() {
            throw ClientError.Unexpected("MLS mutation pending; reconcile server ACK before retry")
        }
        traceRemovalLeaves(removeUserIds, group: group)
        log.debug("TTTTT AAAA BEFORE ADD MEMBER WITH REMOVALS, EPOCH: \(group.epoch())")
        let commitBundle = try group.commitMemberAddWithRemovals(provider: provider, sender: identity, removeUserIds: removeUserIds, addMembers: addMembers)
        try group.saveState(provider: provider)
        log.debug("TTTTT AAAA AFTER ADD MEMBER WITH REMOVALS, EPOCH: \(group.epoch())")
        let ratchetTree = group.exportRatchetTree()
        let epoch = Int(group.epoch())
        return (commitBundle, ratchetTree, epoch)
    }

    private func traceRemovalLeaves(_ userIds: [String], group: Group) {
        for target in Set(userIds).sorted() {
            let leaves = group.membersByUserId(userId: target)
            log.info(
                "mls_membership_trace stage=remove_target epoch=\(group.epoch()) target_user=\(target) "
                    + "leaf_count=\(leaves.count) self_leaf_count=\(userId.map { group.membersByUserId(userId: $0).count } ?? 0) "
                    + "operational=\(group.isOperational())",
                subsystems: .mls
            )
            for leaf in leaves {
                log.info("mls_membership_trace stage=remove_leaf epoch=\(group.epoch()) target_user=\(target) leaf=\(leaf.index)", subsystems: .mls)
            }
        }
    }
    
    func removeMembersWithRemovals(in cid: String, removeUserIds: [String]) throws {
        assertMutationExecutor()
        let group = try loadGroup(with: cid)
        let (provider, identity) = try generationContext(for: group)
        try group.commitMemberRemovals(provider: provider, sender: identity, removeUserIds: removeUserIds)
    }
}

public extension ClientError {
    class MlsNoProviderError: ClientError, @unchecked Sendable {

    }

    class MlsNoIdentityError: ClientError, @unchecked Sendable {

    }

    class E2eeChannelNotReady: ClientError, @unchecked Sendable {
        init(cid: String, state: E2eeChannelReadiness) {
            super.init("E2EE channel \(cid) is not ready (state: \(state.rawValue)).")
        }
    }
}
