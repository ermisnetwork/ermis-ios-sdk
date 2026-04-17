//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared
import open_mls_ios

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

    func encrypt(inputData: Data, in group: Group) throws -> Data {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let encryptedData = try group.createMessage(provider: provider, sender: identity, plaintext: inputData)
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
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let group = try loadGroup(with: cid.rawValue)
        try group.clearPendingCommit(provider: provider)
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
        return try group.createMessage(provider: provider, sender: identity, plaintext: data)
    }

    func decrypt(data: Data, in group: Group) throws -> E2ePayload {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        guard let identity else {
            throw ClientError.MlsNoIdentityError()
        }
        let processedMessage = try group.processMessage(provider: provider, msg: data)
        try group.saveState(provider: provider)
        guard let content = processedMessage.content else {
            throw ClientError.Unexpected("Decrypt messsage failed: content not found.")
        }
        let e2ePayload = try JSONDecoder().decode(E2ePayload.self, from: content)
        return e2ePayload
    }

    func processMessage(data: Data, in cid: String) throws {
        log.debug("[MLS] processing message", subsystems: .mls)
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
        let group = try loadGroup(with: cid)
        let processedMessage = try group.processMessage(provider: provider, msg: data)
    }

    func joinWithWelcome(cid: String, welcome: Data, ratchetTree: RatchetTree) throws {
        guard let provider else {
            throw ClientError.MlsNoProviderError()
        }
//        do {
            try Group.joinWithWelcome(provider: provider, welcome: welcome, ratchetTree: ratchetTree)
//        } catch {
//            try provider.deleteGroup(cid: cid)
//            try Group.joinWithWelcome(provider: provider, welcome: welcome, ratchetTree: ratchetTree)
//        }
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
}

public extension ClientError {
    class MlsNoProviderError: ClientError, @unchecked Sendable {

    }

    class MlsNoIdentityError: ClientError, @unchecked Sendable {

    }
}
