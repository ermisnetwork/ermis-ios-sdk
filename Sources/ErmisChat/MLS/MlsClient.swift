//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared
import open_mls_ios

struct MlsProcessedApplicationMessage {
    let payload: E2ePayload
    let aad: Data
    let epoch: UInt64
}

public class MlsClient {
    public static let deviceIdKey = "ermis_mls_device_id"
    public static let cursorKey = "ermis_e2e_sync_cursor"

    var provider: Provider?
    var identity: Identity?
    var userId: UserId?
    var hasSetup: Bool = false

    /// Returns the device ID for the current userId, or nil if not available.
    var currentDeviceId: String? {
        guard let userId else { return nil }
        let dict = UserDefaults.standard.dictionary(forKey: MlsClient.deviceIdKey) as? [String: String]
        return dict?[userId]
    }

    init() {
        initLogger()
    }

    public func reset() throws {
//        guard let provider else {
//            throw ClientError.MlsNoProviderError()
//        }
//        try provider.deleteAllGroups()
//        try provider.deleteIdentity()

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
        let dbName = "ermis_mls_" + userId + ".db"
        let dbPath = documentDir.appendingPathComponent(dbName).path
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
        hasSetup = true
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
        let processedMessage = try group.processMessage(provider: provider, msg: data)
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
        do {
            try Group.joinWithWelcome(provider: provider, welcome: welcome, ratchetTree: ratchetTree)
        } catch {
            try provider.deleteGroup(cid: cid)
            try Group.joinWithWelcome(provider: provider, welcome: welcome, ratchetTree: ratchetTree)
        }
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
        var dict = UserDefaults.standard.dictionary(forKey: MlsClient.deviceIdKey) as? [String: String] ?? [:]
        
        if let deviceId = dict[userId] as? String {
            log.debug("[MLSClient] has deviceID: \(dict[userId])")
        } else {
            let deviceId = "ios-" + UUID().uuidString
            dict[userId] = deviceId
            UserDefaults.standard.set(dict, forKey: MlsClient.deviceIdKey)
            log.debug("[MLSClient] generate new deviceID: \(deviceId)")
        }
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
}
