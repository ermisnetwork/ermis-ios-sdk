//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared
import open_mls_ios
import CryptoKit

struct MlsProcessedApplicationMessage {
    let payload: E2ePayload
    let aad: Data
    let epoch: UInt64
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
    private var providerDatabaseURL: URL?

    /// Returns the device ID for the current userId, or nil if not available.
    var currentDeviceId: String? {
        guard let userId else { return nil }
        return deviceIdStore.canonicalDeviceId(for: userId, createIfNeeded: false)
    }

    init(
        storageFolderURL: URL? = nil,
        applicationGroupIdentifier: String? = nil,
        deviceIdStore: MlsDeviceIdStore? = nil
    ) {
        self.storageFolderURL = storageFolderURL
        self.userDefaults = applicationGroupIdentifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
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
    }

    public func setup(with userId: String) throws {
//        guard self.userId != userId || !hasSetup else {
//            generateDeviceIdIfNeeded(for: userId)
//            return
//        }
        
        
        guard let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        self.userId = userId
        generateDeviceIdIfNeeded(for: userId)
        let storageRoot = storageFolderURL ?? documentDir
        let mlsFolder = storageRoot.appendingPathComponent("mls", isDirectory: true)
        try FileManager.default.createDirectory(at: mlsFolder, withIntermediateDirectories: true)
        let dbName = "ermis_mls_" + Self.storageNamespace(for: userId) + ".db"
        let dbURL = mlsFolder.appendingPathComponent(dbName)
        let legacyURL = documentDir.appendingPathComponent("ermis_mls_" + userId + ".db")
        try Self.migrateLegacyProviderIfNeeded(from: legacyURL, to: dbURL)
        let dbPath = dbURL.path
        let provider = try Provider.newWithPath(dbPath: dbPath)

        if let identityBytes = try? provider.loadIdentity() {
            self.identity = try Identity.fromBytes(provider: provider, data: identityBytes)
        } else {
            let identity = try Identity(provider: provider, userId: userId)
            self.identity = identity
            let identityBytes = try identity.toBytes()
            try provider.storeIdentity(userId: userId, identityBytes: identityBytes)
        }

        self.provider = provider
        providerDatabaseURL = dbURL
        hasSetup = true
    }

    func purgeCurrentUserData() throws {
        guard let currentUserId = userId else { return }
        let databaseURL = providerDatabaseURL
        if let provider {
            try provider.deleteAllGroups()
            try provider.deleteIdentity()
        }
        provider = nil
        identity = nil
        userId = nil
        hasSetup = false
        providerDatabaseURL = nil

        if let databaseURL {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        deviceIdStore.removeUser(currentUserId)
        removeUserScopedDefault(forKey: Self.cursorKey, userId: currentUserId)
    }

    private func removeUserScopedDefault(forKey key: String, userId: String) {
        var values = userDefaults.dictionary(forKey: key) ?? [:]
        values.removeValue(forKey: userId)
        userDefaults.set(values, forKey: key)
    }

    private static func storageNamespace(for userId: String) -> String {
        SHA256.hash(data: Data(userId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func migrateLegacyProviderIfNeeded(from legacyURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard legacyURL.standardizedFileURL != destinationURL.standardizedFileURL,
              !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacyURL.path + suffix)
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
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
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }

        let group = try Group.createWithCid(provider: provider, founder: identity, cid: cid)
        return group
    }

    func loadGroup(with cid: String) throws -> Group {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let group = try Group.loadFromStorage(provider: provider, cid: cid)
        return group
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
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        
        if group.hasPendingCommit() {
            try group.clearPendingCommit(provider: provider)
        }
        log.debug("TTTTT AAAA BEFORE ADD MEMBER, EPOCH: \(group.epoch())")
        let commitBunddle = try group.addMembers(provider: provider, sender: identity, newMembers: memberKeyPackages)
        log.debug("TTTTT AAAA AFTER ADD MEMBER, EPOCH: \(group.epoch())")
        return commitBunddle
    }

    func removeMember(_ userId: String, in group: Group) throws -> CommitBundle {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let commitBundle = try group.removeUser(provider: provider, sender: identity, userId: userId)
        return commitBundle
    }

    func removeMembers(_ userIds: [String], in group: Group) throws -> CommitBundle {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        log.debug("TTTTT AAAA BEFORE REMOVE USER, EPOCH: \(group.epoch())")
        let commitBundle = try group.removeUsers(provider: provider, sender: identity, userIds: userIds)
        log.debug("TTTTT AAAA AFTER REMOVE USER, EPOCH: \(group.epoch())")
        return commitBundle
    }

    func getKeyPackage() -> Data? {
        guard let provider else {
            return nil
        }
        guard let identity else {
            return nil
        }
        let keyPackage = identity.keyPackage(provider: provider)
        return keyPackage.toBytes()
    }

    func getKeyPackage(count: Int = 50) -> [Data] {
        guard let provider else {
            return []
        }
        guard let identity else {
            return []
        }
        let keyPackages = identity.keyPackages(provider: provider, count: UInt32(count))
        return keyPackages.map { $0.toBytes() }
    }

    func encrypt(
        inputData: Data,
        in group: Group,
        trace: E2eeSendTrace.Context? = nil
    ) throws -> Data {
        guard let provider else {
            let error = ClientError.MlsNoProviderError()
            trace?.failure(stage: "mls_precondition_failed", error: error)
            throw error
        }
        guard let identity else {
            let error = ClientError.MlsNoIdentityError()
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
        guard let provider else {
            let error = ClientError.MlsNoProviderError()
            trace?.failure(stage: "mls_precondition_failed", error: error)
            throw error
        }
        guard let identity else {
            let error = ClientError.MlsNoIdentityError()
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
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let group = try loadGroup(with: cid.rawValue)
        try group.mergePendingCommit(provider: provider)
        try group.saveState(provider: provider)
    }

    func clearPendingCommit(in cid: ChannelId) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let group = try loadGroup(with: cid.rawValue)
        try group.clearPendingCommit(provider: provider)
    }

    func commitPendingProposal(in cid: ChannelId) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let group = try loadGroup(with: cid.rawValue)
        try group.commitPendingProposals(provider: provider, sender: identity)
    }

    func clearPendingProposal(in cid: ChannelId) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let group = try loadGroup(with: cid.rawValue)
        try group.clearPendingProposals(provider: provider)
    }

    func exportGroupInfo(of group: Group, withRatchetTree: Bool = true) throws -> Data {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        return try group.exportGroupInfo(provider: provider, sender: identity, withRatchetTree: true)
    }

    func encrypt(data: Data, in group: Group) throws -> Data {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let encryptedData = try group.createMessage(provider: provider, sender: identity, plaintext: data)
        try group.saveState(provider: provider)
        return encryptedData
    }

    func processApplicationMessage(data: Data, in group: Group) throws -> MlsProcessedApplicationMessage {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let processedMessage = try group.processMessageDeferred(provider: provider, msg: data)
        guard processedMessage.messageType == .applicationMessage else {
            throw ClientError.Unexpected("Expected an MLS application message.")
        }
        guard let content = processedMessage.content else {
            throw ClientError.Unexpected("Decrypt messsage failed: content not found.")
        }
        let e2ePayload = try JSONDecoder().decode(E2ePayload.self, from: content)
        return MlsProcessedApplicationMessage(
            payload: e2ePayload,
            aad: processedMessage.aad,
            epoch: processedMessage.epoch
        )
    }

    func saveState(of group: Group) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        try group.saveState(provider: provider)
    }

    /// Processes an MLS protocol message without persisting the group's ratchet state.
    /// Commit callers persist their durable proof before `saveState(of:)` so a crash replay can
    /// distinguish an applied event from an unrelated epoch advance.
    func processProtocolMessage(data: Data, in group: Group) throws -> ProcessedMessage {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let processedMessage = try group.processMessage(provider: provider, msg: data)
        guard processedMessage.messageType != .applicationMessage else {
            throw ClientError.Unexpected("Expected an MLS protocol message.")
        }
        return processedMessage
    }

    @discardableResult
    func processMessage(data: Data, in cid: String) throws -> ProcessedMessage {
        log.debug("[MLS] processing message", subsystems: .mls)
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let group = try loadGroup(with: cid)
        let processedMessage = try group.processMessage(provider: provider, msg: data)
        try group.saveState(provider: provider)
        return processedMessage
    }

    func joinWithWelcome(cid: String, welcome: Data, ratchetTree: RatchetTree) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        log.debug("[MLS] Join with welcome", subsystems: .mls)
        try Group.joinWithWelcome(provider: provider, welcome: welcome, ratchetTree: ratchetTree)
    }

    func ownsDeviceId(_ deviceId: String, userId: UserId) -> Bool {
        deviceIdStore.owns(deviceId: deviceId, for: userId)
    }

    func externalJoin(groupInfo: Data) throws -> ExternalJoinResult {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let externalJoinResult = try joinExternal(provider: provider, identity: identity, groupInfo: groupInfo, ratchetTree: nil)
        return externalJoinResult
    }

    func generateDeviceIdIfNeeded(for userId: String) {
        _ = deviceIdStore.canonicalDeviceId(for: userId)
    }
    
    func deleteGroup(cid: String) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        try provider.deleteGroup(cid: cid)
    }
    
    func deleteMessage(messageId: String) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        
    }
    
    func addMembersWithRemovals(in cid: String, removeUserIds: [String], addMembers: [KeyPackage]) throws -> (CommitBundle, RatchetTree, Int) {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let group = try loadGroup(with: cid)
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
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let group = try loadGroup(with: cid)
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
