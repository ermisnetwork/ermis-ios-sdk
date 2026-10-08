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

    var provider: Provider?
    var identity: Identity?
    var userId: UserId?
    var hasSetup: Bool = false
    let userDefaults: UserDefaults
    let deviceIdStore: MlsDeviceIdStore
    private let storageFolderURL: URL?
    private let legacyStorageFolderURLs: [URL]
    private var providerDatabaseURL: URL?
    private var providerDatabaseCleanupURLs: [URL] = []
    private var currentProviderMigrationMarkerKey: String?
    private var mutationExecutorAssertion: (() -> Void)?
    private var generationProviders: [String: Provider] = [:]
    private var generationIdentities: [String: Identity] = [:]
    private var providerContextByGroupId: [Data: String] = [:]
    private let generationMarkerPrefix = "ermis_mls_generation_v1:"
    private let historicalGenerationMarkerPrefix = "ermis_mls_generation_history_v1:"
    private let pendingGenerationJoinPrefix = "ermis_mls_generation_join_v1:"

    struct GroupGenerationMarker: Codable, Equatable {
        let cid: String
        let generation: UInt64
        let groupId: Data?
        let epoch: UInt64
        let status: String
        let operationId: String?
        let providerPath: String?

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
        let generationDatabaseURLs = markerKeys.compactMap { key -> URL? in
            guard let data = userDefaults.data(forKey: key) else { return nil }
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

        for databaseURL in databaseURLs {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
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
        let marker = loadPendingGenerationJoin(cid: cid) ?? loadGenerationMarker(cid: cid)
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

    func loadGenerationMarker(cid: String) -> GroupGenerationMarker? {
        guard let key = generationMarkerKey(prefix: generationMarkerPrefix, cid: cid),
              let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GroupGenerationMarker.self, from: data)
    }

    func loadGenerationMarker(cid: String, generation: UInt64) -> GroupGenerationMarker? {
        guard let key = historicalGenerationMarkerKey(cid: cid, generation: generation),
              let data = userDefaults.data(forKey: key) else {
            let current = loadGenerationMarker(cid: cid)
            return current?.generation == generation ? current : nil
        }
        return try? JSONDecoder().decode(GroupGenerationMarker.self, from: data)
    }

    func saveGenerationMarker(_ marker: GroupGenerationMarker) throws {
        guard let key = generationMarkerKey(prefix: generationMarkerPrefix, cid: marker.cid),
              let historicalKey = historicalGenerationMarkerKey(
                cid: marker.cid,
                generation: marker.generation
              ) else {
            throw ClientError.MlsNoIdentityError()
        }
        let encoded = try JSONEncoder().encode(marker)
        userDefaults.set(encoded, forKey: key)
        userDefaults.set(encoded, forKey: historicalKey)
    }

    func loadPendingGenerationJoin(cid: String) -> GroupGenerationMarker? {
        guard let key = generationMarkerKey(prefix: pendingGenerationJoinPrefix, cid: cid),
              let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(GroupGenerationMarker.self, from: data)
    }

    func savePendingGenerationJoin(_ marker: GroupGenerationMarker) throws {
        guard let key = generationMarkerKey(
            prefix: pendingGenerationJoinPrefix,
            cid: marker.cid
        ) else {
            throw ClientError.MlsNoIdentityError()
        }
        let encoded = try JSONEncoder().encode(marker)
        userDefaults.set(encoded, forKey: key)
    }

    func removePendingGenerationJoin(cid: String) {
        guard let key = generationMarkerKey(prefix: pendingGenerationJoinPrefix, cid: cid) else {
            return
        }
        userDefaults.removeObject(forKey: key)
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
            try group.clearPendingCommit(provider: provider)
        }
        log.debug("TTTTT AAAA BEFORE ADD MEMBER, EPOCH: \(group.epoch())")
        let commitBunddle = try group.addMembers(provider: provider, sender: identity, newMembers: memberKeyPackages)
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
        log.debug("TTTTT AAAA BEFORE REMOVE USER, EPOCH: \(group.epoch())")
        let commitBundle = try group.removeUsers(provider: provider, sender: identity, userIds: userIds)
        log.debug("TTTTT AAAA AFTER REMOVE USER, EPOCH: \(group.epoch())")
        return commitBundle
    }

    func getKeyPackage() -> Data? {
        assertMutationExecutor()
        guard let provider else {
            return nil
        }
        guard let identity else {
            return nil
        }
        let keyPackage = identity.keyPackage(provider: provider)
        return keyPackage.toBytes()
    }

    func getKeyPackage(count: Int) throws -> [Data] {
        assertMutationExecutor()
        guard (1...100).contains(count) else {
            throw ClientError.Unexpected("MLS KeyPackage count must be between 1 and 100.")
        }
        guard let provider else { throw ClientError.MlsNoProviderError() }
        guard let identity else { throw ClientError.MlsNoIdentityError() }
        let keyPackages = identity.keyPackages(provider: provider, count: UInt32(count))
        return keyPackages.map { $0.toBytes() }
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
        let createStartedAt = E2eeSendTrace.nowNanoseconds()
        trace?.info(
            stage: "mls_create_started",
            epoch: epoch,
            payloadBytes: inputData.count,
            authenticatedAAD: false
        )
        let encryptedData: Data
        do {
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
        try group.mergePendingCommit(provider: provider)
        try group.saveState(provider: provider)
    }

    func clearPendingCommit(in cid: ChannelId) throws {
        assertMutationExecutor()
        let group = try loadGroup(with: cid.rawValue)
        let provider = try generationProvider(for: group)
        try group.clearPendingCommit(provider: provider)
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
        let encryptedData = try group.createMessage(provider: provider, sender: identity, plaintext: data)
        try group.saveState(provider: provider)
        return encryptedData
    }

    func processApplicationMessage(data: Data, in group: Group) throws -> MlsProcessedApplicationMessage {
        assertMutationExecutor()
        let provider = try generationProvider(for: group)
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
    }

    /// Processes an MLS protocol message and preserves its type plus before/after epoch metadata.
    /// Commit callers write the durable event proof before this call, validate the returned epoch,
    /// and then explicitly store the complete group with `saveState(of:)`.
    func processProtocolMessage(data: Data, in group: Group) throws -> MlsProcessedProtocolMessage {
        assertMutationExecutor()
        let provider = try generationProvider(for: group)
        let epochBefore = group.epoch()
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
        try result.group.saveState(provider: candidate)
        generationProviders[path] = candidate
        generationIdentities[path] = candidateIdentity
        providerContextByGroupId[result.group.groupId()] = path
        try savePendingGenerationJoin(.init(cid: cid, generation: generation,
            groupId: result.group.groupId(), epoch: result.group.epoch(), status: "external_join_prepared",
            operationId: nil, providerPath: path))
        return result
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
            try group.clearPendingCommit(provider: provider)
        }
        log.debug("TTTTT AAAA BEFORE ADD MEMBER WITH REMOVALS, EPOCH: \(group.epoch())")
        let commitBundle = try group.commitMemberAddWithRemovals(provider: provider, sender: identity, removeUserIds: removeUserIds, addMembers: addMembers)
        log.debug("TTTTT AAAA AFTER ADD MEMBER WITH REMOVALS, EPOCH: \(group.epoch())")
        let ratchetTree = group.exportRatchetTree()
        let epoch = Int(group.epoch())
        return (commitBundle, ratchetTree, epoch)
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
