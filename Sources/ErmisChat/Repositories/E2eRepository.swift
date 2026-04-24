//
// Copyright 2025 Ermis Inc.
//

import Foundation
import open_mls_ios

class E2eRepository: EventsControllerDelegate {
    let database: DatabaseContainer
    let eventNotificationCenter: EventNotificationCenter
    let mlsClient: MlsClient
    let apiClient: APIClient

    let eventController: EventsController

    private let keyPackageAmount = 50

    private static let loginTimeKey = "ermis_mls_login_time"

    /// The timestamp when the current user session started on this device.
    /// Stored in UserDefaults so it survives app restarts but is device-local.
    var loginTime: Date? {
        get { UserDefaults.standard.object(forKey: Self.loginTimeKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.loginTimeKey) }
    }

    /// Returns the e2eSyncCursor value (milliseconds since epoch) for a given channel ID, or nil if not set.
    /// Scoped by the current userId so cursors from different users don't interfere.
    private func e2eSyncCursor(for channelId: String) -> Int64? {
        guard let userId = mlsClient.userId else { return nil }
        let allUsers = UserDefaults.standard.dictionary(forKey: MlsClient.cursorKey) as? [String: [String: NSNumber]]
        return allUsers?[userId]?[channelId]?.int64Value
    }

    /// Saves e2eSyncCursor values (milliseconds since epoch) for the given channel IDs into UserDefaults.
    /// Scoped by the current userId so cursors from different users don't interfere.
    private func saveE2eSyncCursorsToUserDefaults(_ cursors: [String: Int64]) {
        guard let userId = mlsClient.userId else { return }
        var allUsers = UserDefaults.standard.dictionary(forKey: MlsClient.cursorKey) as? [String: [String: NSNumber]] ?? [:]
        var userCursors = allUsers[userId] ?? [:]
        for (cid, ms) in cursors {
            userCursors[cid] = NSNumber(value: ms)
        }
        allUsers[userId] = userCursors
        UserDefaults.standard.set(allUsers, forKey: MlsClient.cursorKey)
    }

    /// Removes the e2eSyncCursor for a given channel ID from UserDefaults.
    /// Called when an MLS group is deleted so the stale cursor doesn't persist.
    private func removeE2eSyncCursor(for channelId: String) {
        guard let userId = mlsClient.userId else { return }
        var allUsers = UserDefaults.standard.dictionary(forKey: MlsClient.cursorKey) as? [String: [String: NSNumber]] ?? [:]
        var userCursors = allUsers[userId] ?? [:]
        userCursors.removeValue(forKey: channelId)
        allUsers[userId] = userCursors
        UserDefaults.standard.set(allUsers, forKey: MlsClient.cursorKey)
    }

    /// Serial queue that serializes all MLS decrypt operations.
    /// All sources (WebSocket, API, NSE via shared DB) funnel through here,
    /// so MLS `processMessage` is never called concurrently for the same group.
    private let decryptQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "io.ermis.e2e.decrypt"
        return q
    }()

    /// Guards against multiple concurrent syncPage tasks.
    /// Only one sync (from either `performE2eSync` or `performE2eChannelSync`) can run at a time.
    private let syncLock = NSLock()
    private var isSyncing = false

    init(database: DatabaseContainer,
         eventNotificationCenter: EventNotificationCenter,
         mlsClient: MlsClient,
         apiClient: APIClient) {
        self.database = database
        self.apiClient = apiClient
        self.mlsClient = mlsClient
        self.eventNotificationCenter = eventNotificationCenter
        self.eventController = EventsController(notificationCenter: eventNotificationCenter)
        eventController.delegate = self
    }

    func eventsController(_ controller: EventsController, didReceiveEvent event: any Event) {
        if let event = event as? HealthCheckEvent {
            handleHealthCheckEvent(event)
        } else if let event = event as? MessageNewEvent {
            decryptNewMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? NotificationMessageNewEvent {
            decryptNewMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? MLSEvent {
            handleMlsEvent(event)
        } else if let event = event as? MemberRemovedEvent {
            handleNotificationMemberRemoveEvent(event)
        } else if let event = event as? NotificationInviteRespondBackEvent {
            switch event.respondBackType {
            case .accept:
                handleNotificationInviteAcceptedEvent(event)
            case .reject:
                handleNotificationInviteRejectedEvent(event)
            case .skip:
                handleNotificationInviteSkippedEvent(event)
            case .messagingReject:
                break
            }
        }
    }

    private func handleNotificationInviteAcceptedEvent(_ event: NotificationInviteRespondBackEvent) {
        guard event.mlsEnabled else { return }
        performE2eChannelSync(cid: event.cid)
    }

    private func handleNotificationInviteRejectedEvent(_ event: NotificationInviteRespondBackEvent) {
        guard event.mlsEnabled else { return }
        performE2eChannelSync(cid: event.cid)
    }

    private func handleNotificationInviteSkippedEvent(_ event: NotificationInviteRespondBackEvent) {
        guard event.mlsEnabled else { return }
        performE2eChannelSync(cid: event.cid)
    }
    
    private func handleNotificationMemberRemoveEvent(_ event: MemberRemovedEvent) {
//        guard event.member.userId == mlsClient.userId else {
//            return
//        }
//        guard mlsClient.isGroupLoaded(cid: event.cid.rawValue) else {
//            return
//        }
//        do {
//            log.debug("[MLS] Current user removed from channel, deleting MLS group for \(event.cid)", subsystems: .mls)
//            try deleteGroup(cid: event.cid.rawValue)
//        } catch {
//            log.error("[MLS] Failed to delete MLS group after removal: \(error)", subsystems: .mls)
//        }
    }

    private func handleMlsEvent(_ mlsEvent: MLSEvent) {
        let mlsProtocol = mlsEvent.mlsProtocol
        let cid = mlsEvent.cid.rawValue
        if let deviceId = mlsProtocol.deviceId, let currentDeviceId = mlsClient.currentDeviceId, deviceId == currentDeviceId {
            log.debug("[MLS] ignored event from self", subsystems: .mls)
            return
        }
        decryptQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                switch mlsEvent.mlsProtocol.type {
                case .commit:
                    guard let commit = mlsProtocol.commit else {
                        return
                    }
                    let group = try self.mlsClient.loadGroup(with: cid)
                    guard Int(group.epoch()) == mlsProtocol.epoch - 1 else {
                        log.debug("[MLS] Skipping commit: local epoch \(group.epoch()) != expected \(mlsProtocol.epoch - 1)", subsystems: .mls)
                        return
                    }
                    log.debug("[MLS] Processing commit message", subsystems: .mls)
                    try self.mlsClient.processMessage(data: commit.data, in: cid)
                case .externalCommit:
                    guard let commit = mlsProtocol.commit else {
                        return
                    }
                    let group = try self.mlsClient.loadGroup(with: cid)
                    guard group.epoch() == mlsProtocol.epoch - 1 else {
                        log.debug("[MLS] Skipping commit: local epoch \(group.epoch()) != expected \(mlsProtocol.epoch - 1)", subsystems: .mls)
                        return
                    }
                    try self.mlsClient.processMessage(data: commit.data, in: cid)
                case .welcome:
//                    break
                    guard !self.shouldSkipWelcome(cid: cid) else {
                        log.debug("[MLS] Skipping welcome: group already exists for \(cid)", subsystems: .mls)
                        return
                    }
                    if let targetUserIds = mlsProtocol.targetUserIds,
                       let currentUserId = mlsClient.userId,
                       !targetUserIds.contains(currentUserId) {
                        log.debug("[E2eSync] Skipping welcome not targeted at current user", subsystems: .mls)
                        return
                    }
                    guard let welcome = mlsProtocol.welcome,
                          let ratchetTreeData = mlsProtocol.ratchetTree?.data,
                          let ratchetTree = try? RatchetTree.fromBytes(data: ratchetTreeData) else {
                        return
                    }
                    try self.mlsClient.joinWithWelcome(cid: mlsEvent.cid.rawValue, welcome: welcome.data, ratchetTree: ratchetTree)
                    self.saveMlsGroupJoinedAt(cidString: mlsEvent.cid.rawValue)
                case .proposal:
                    break
                }
            } catch {
                log.error("[MLS] Failed to process event: \(mlsEvent)", subsystems: .mls)
            }
        }
    }

    private func decryptNewMessageEventIfNeeded(message: ChatMessage, cid: ChannelId) {
        log.debug("[MLS] Decrypt message with epoch: \(message.mlsEpoch)")
        guard let encryptedData = message.encryptedData else { return }
        decryptMessagePayload(messageId: message.id, encryptedData: encryptedData, cid: cid)
    }

    private func handleHealthCheckEvent(_ event: HealthCheckEvent) {
        // Send mising keypackages to BE
        guard let keyPackagesRemaining = event.keyPackagesRemaining else {
            return
        }
        let amountOfKeyPackagesMissing = keyPackageAmount - keyPackagesRemaining
        guard amountOfKeyPackagesMissing > 0 , amountOfKeyPackagesMissing <= keyPackageAmount else {
            return
        }
        let keyPackages = mlsClient.getKeyPackage(count: amountOfKeyPackagesMissing).map { $0.uint8Array }
        apiClient.request(endpoint: .uploadKeyPackages(keyPackages: keyPackages)) { result in
            log.debug("[MLS] Upload missing \(amountOfKeyPackagesMissing) keypackages result: \(result)", subsystems: .mls)
        }
    }

    // MARK: - E2EE Sync

    /// Resolves the sync cursor (milliseconds since epoch) for a single channel.
    ///
    /// The resolution order is:
    /// 1. Saved cursor in UserDefaults (from a previous sync).
    /// 2. `memberCreatedAt` from Core Data.
    /// 3. `loginTime` if the membership was created after this device logged in.
    ///
    /// Returns `nil` when no cursor can be determined (e.g. the device hasn't joined the MLS group yet).
    private func resolveSyncCursor(cidString: String, mlsJoinedAt: NSDate?, memberCreatedAt: NSDate?, deviceLoginTime: Date?) -> Int64? {
        // 1. Check UserDefaults for an existing sync cursor.
        if let savedCursor = e2eSyncCursor(for: cidString) {
            if let memberCreatedAt,
               Int64(memberCreatedAt.timeIntervalSince1970 * 1000) > savedCursor {
                if let group = try? mlsClient.loadGroup(with: cidString) {
                    do {
                        try mlsClient.deleteGroup(cid: cidString)
                    } catch {
                        log.error("[MLS] Remove group: \(cidString) that user has been kick failed with error \(error)", subsystems: .mls)
                    }
                }
                return Int64(memberCreatedAt.timeIntervalSince1970 * 1000)
            }
            return savedCursor
        }
//        // 2. Fall back to memberCreatedAt from Core Data.
        if let anchor = mlsJoinedAt {
            return Int64(anchor.timeIntervalSince1970 * 1000)
        }
        // 3. If the user joined on another device after this device logged in, use loginTime.
        if let loginTime = deviceLoginTime,
           let memberCreatedAt = memberCreatedAt as? Date,
           memberCreatedAt > loginTime {
            return Int64(loginTime.timeIntervalSince1970 * 1000)
        }
        
        if let memberCreatedAt {
            return Int64(memberCreatedAt.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    /// Fetches all missed E2EE events for every MLS-enabled channel since the last known cursor,
    /// applying protocol messages and decrypting application messages in order.
    func performE2eSync() {
        syncLock.lock()
        guard !isSyncing else {
            syncLock.unlock()
            log.debug("[E2eSync] Skipping sync — another sync is already in progress", subsystems: .mls)
            return
        }
        isSyncing = true
        syncLock.unlock()

        var cursors: [String: Int64] = [:]
        let deviceLoginTime = loginTime
        database.viewContext.performAndWait {
            let channels = ChannelDTO.fetchAllJoinedMlsEnabled(context: self.database.viewContext)
            for ch in channels {
                if let cursor = self.resolveSyncCursor(
                    cidString: ch.cid,
                    mlsJoinedAt: ch.mlsGroupJoinedAt,
                    memberCreatedAt: ch.membership?.memberCreatedAt,
                    deviceLoginTime: deviceLoginTime
                ) {
                    cursors[ch.cid] = cursor
                }
            }
        }
        guard !cursors.isEmpty else {
            finishSync()
            return
        }
        log.debug("[E2eSync] Starting sync for \(cursors.count) channel(s)", subsystems: .mls)
        syncPage(cursors: cursors)
    }

    /// Called after a channel list API response is saved to the database.
    /// For each MLS-enabled channel whose local MLS group does not yet exist,
    /// performs an external join so the device can decrypt messages in that channel.
    /// For channels whose group already exists locally (e.g. MLS DB survived logout),
    /// ensures `mlsGroupJoinedAt` is set so E2E sync has a valid cursor.
    ///
    /// - Parameter cids: The MLS-enabled channel IDs from the saved channel list payload.
    func handleNewEncryptedChannels(_ cids: [ChannelId]) {
        var needsSync = false
        for cid in cids {
            if mlsClient.isGroupLoaded(cid: cid.rawValue) {
                // Group already exists locally (MLS DB was preserved across logout).
                // Ensure mlsGroupJoinedAt is set so performE2eSync has a cursor.
                log.debug("[E2E] already has group, no need external join", subsystems: .mls)
                database.write { session in
                    guard let dto = session.channel(cid: cid),
                          dto.mlsGroupJoinedAt == nil else { return }
                    dto.mlsGroupJoinedAt = Date().bridgeDate
                }
                needsSync = true
                continue
            }
            log.debug("[E2E] No local group for \(cid), performing external join", subsystems: .mls)
            externalJoinChannel(cid: cid) { error in
                if let error {
                    log.error("[E2E] externalJoinChannel failed for \(cid): \(error)", subsystems: .mls)
                }
            }
        }
        // If any channel already had a local group, trigger sync now
        // (the initial health-check sync ran before the channel list was loaded).
        if needsSync {
            performE2eSync()
        }
    }

    /// Deletes local MLS groups that are no longer in the active channel list.
    /// Compares all MLS-enabled channels stored in the database against the channel CIDs
    /// returned by the latest channel list API response. Any local MLS group whose CID is
    /// NOT in `activeChannelCids` is deleted along with its sync cursor.
    ///
    func cleanupOrphanedMlsGroups() {
//        database.viewContext.performAndWait {
//            let mlsJoinedChannels = ChannelDTO.fetchAllJoinedMlsEnabled(context: self.database.viewContext)
//        
//            let mlsCIds = Set(mlsJoinedChannels.map { $0.cid })
//            do {
//                let mlsGroupIds = try mlsClient.getStoredGroupIdList()
//                let orphanedGroupIds = Set(mlsGroupIds).subtracting(mlsCIds)
//                for orphanedGroupId in orphanedGroupIds {
//                    log.debug("[MLS] Deleting orphaned MLS group for \(orphanedGroupId)", subsystems: .mls)
//                    try deleteGroup(cid: orphanedGroupId)
//                    log.debug("[MLS] Deleted orphaned MLS group for \(orphanedGroupId)", subsystems: .mls)
//                }
//            } catch {
//                log.error("[MLS] Cleanup orphaned MlsGroups failed: \(error)", subsystems: .mls)
//            }
//        }
    }

    /// Fetches missed E2EE events for a single channel since its last known cursor,
    /// applying protocol messages and decrypting application messages in order.
    ///
    /// Uses the same `e2eSyncCursor` / `mlsGroupJoinedAt` anchor as `performE2eSync`.
    /// Automatically paginates if `has_more` is `true` in the response.
    ///
    /// - Parameter cid: The channel to sync.
    func performE2eChannelSync(cid: ChannelId) {
        syncLock.lock()
        guard !isSyncing else {
            syncLock.unlock()
            log.debug("[E2eSync] Skipping single-channel sync for \(cid) — another sync is already in progress", subsystems: .mls)
            return
        }
        isSyncing = true
        syncLock.unlock()

        var since: Int64?
        let deviceLoginTime = loginTime
        database.viewContext.performAndWait {
            guard let dto = ChannelDTO.load(cid: cid, context: self.database.viewContext) else { return }
            since = self.resolveSyncCursor(
                cidString: cid.rawValue,
                mlsJoinedAt: dto.mlsGroupJoinedAt,
                memberCreatedAt: dto.membership?.memberCreatedAt,
                deviceLoginTime: deviceLoginTime
            )
        }

        guard let since else {
            finishSync()
            log.debug("[E2eSync] Skipping sync for \(cid): device has not joined the MLS group yet", subsystems: .mls)
            return
        }
        log.debug("[E2eSync] Starting single-channel sync for \(cid) since \(since)", subsystems: .mls)
        syncChannelPage(cid: cid, since: since)
    }

    private func syncChannelPage(cid: ChannelId, since: Int64) {
        // Delegate to the full sync which handles all channels including this one.
        // The sync lock is already held (set by performE2eChannelSync), so we build
        // cursors for just this channel and run through syncPage.
        syncPage(cursors: [cid.rawValue: since])
    }

    private func syncPage(cursors: [String: Int64]) {
        let body = E2eSyncRequestBody(cursors: cursors)
        apiClient.request(endpoint: .e2eSync(body: body)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                log.error("[E2eSync] Request failed: \(error)", subsystems: .mls)
                self.finishSync()
            case .success(let payload):
                var nextCursors: [String: Int64] = [:]

                for (cidString, channelPayload) in payload.channels {
                    guard !channelPayload.events.isEmpty else { continue }

                    guard let cid = try? ChannelId(cid: cidString) else {
                        log.warning("[E2eSync] Skipping unknown cid '\(cidString)'", subsystems: .mls)
                        continue
                    }

                    // Only process events whose createdAt is strictly after the cursor
                    // to avoid reprocessing boundary events.
                    let cursorMs = cursors[cidString] ?? 0
                    let newEvents = channelPayload.events.filter { event in
                        Int64(event.createdAt.timeIntervalSince1970 * 1000) > cursorMs
                    }

                    guard !newEvents.isEmpty else { continue }

                    // Process filtered events for this channel in order on the serial decryptQueue.
                    self.processE2eSyncEvents(newEvents, cid: cid, cidString: cidString)

                    // Advance the cursor to the last event's created_at.
                    if let lastEvent = newEvents.last {
                        nextCursors[cidString] = Int64(lastEvent.createdAt.timeIntervalSince1970 * 1000)
                    }

                    // If more pages remain, carry the old cursor so we don't lose it.
                    if channelPayload.hasMore, nextCursors[cidString] == nil {
                        nextCursors[cidString] = cursors[cidString]
                    }
                }

                // Persist updated cursors to the DB.
                if !nextCursors.isEmpty {
                    self.saveSyncCursors(nextCursors)
                }

                // Paginate for channels that still have more events.
                var remaining: [String: Int64] = [:]
                for (cid, ch) in payload.channels where ch.hasMore {
                    remaining[cid] = nextCursors[cid] ?? cursors[cid] ?? 0
                }
                if !remaining.isEmpty {
                    log.debug("[E2eSync] Paginating for \(remaining.count) channel(s)", subsystems: .mls)
                    self.syncPage(cursors: remaining)
                } else {
                    self.finishSync()
                }
            }
        }
    }

    /// Marks the current sync operation as finished so a new one can start.
    private func finishSync() {
        syncLock.lock()
        isSyncing = false
        syncLock.unlock()
    }

    /// Enqueues all events for one channel onto the serial `decryptQueue` so that
    /// protocol messages are applied before the application messages that follow them.
    private func processE2eSyncEvents(_ events: [E2eSyncEventPayload], cid: ChannelId, cidString: String) {
        decryptQueue.addOperation { [weak self] in
            guard let self else { return }
            for event in events {
                switch event {
                case .protocol(let data):
                    self.applyE2eSyncProtocolEvent(data, cidString: cidString)
                case .application(let data):
                    // Call the synchronous body directly — we are already on decryptQueue,
                    // so we must NOT re-enqueue via decryptMessagePayload (that would deadlock
                    // the serial queue waiting on itself).
                    self.decryptMessagePayloadSync(
                        messageId: data.id,
                        encryptedData: Data(data.mlsCiphertext),
                        cid: cid
                    )
                }
            }
        }
    }

    /// Synchronous decryption body. Must only be called from within a `decryptQueue` operation.
    /// External callers should use `decryptMessagePayload` which enqueues this onto the queue.
    private func decryptMessagePayloadSync(
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        completion: ((_ result: Result<E2ePayload, Error>) -> Void)? = nil
    ) {
        // Re-check the DB cache — a prior operation may have populated it.
        var cachedPayload: E2ePayload?
        database.viewContext.performAndWait {
            if let dto = MessageDecryptDTO.load(messageId: messageId, context: self.database.viewContext) {
                cachedPayload = try? dto.asPayload()
            }
        }

        if let cached = cachedPayload {
            completion?(.success(cached))
            return
        }

        // No cache — run MLS decrypt.
        do {
            let group = try mlsClient.loadGroup(with: cid.rawValue)
            log.debug("[MLS] Current group epoch: \(group.epoch())", subsystems: .mls)
            let payload = try mlsClient.decrypt(data: encryptedData, in: group)

            database.write { session in
                try session.saveMessageDecrypt(payload: payload, messageId: messageId)
                // Also update MessageDTO.text directly so the channel list preview
                // (ChannelDTO.previewMessage → MessageDTO.text) reflects the decrypted content.
                session.message(id: messageId)?.text = payload.text
            } completion: { error in
                if let error {
                    log.error("Failed to save decrypted message cache for \(messageId): \(error)")
                }
            }

            completion?(.success(payload))
        } catch {
            log.error("Failed to decrypt message \(messageId): \(error)")
            completion?(.failure(error))
        }
    }

    private func applyE2eSyncProtocolEvent(_ data: E2eSyncProtocolData, cidString: String) {
        do {
            switch data.type {
            case .commit, .externalCommit:
                let group = try self.mlsClient.loadGroup(with: cidString)
                guard group.epoch() == data.epoch - 1 else {
                    log.debug("[MLS] Skipping commit: local epoch \(group.epoch()) != expected \(data.epoch - 1)", subsystems: .mls)
                    return
                }
                
                if let bytes = data.commit {
                    log.debug("[MLS] Processing commit message", subsystems: .mls)
                    try mlsClient.processMessage(data: Data(bytes), in: cidString)
                }
            case .welcome:
                
                guard !self.shouldSkipWelcome(cid: cidString) else {
                    log.debug("[MLS] Skipping welcome: group already exists for \(cidString)", subsystems: .mls)
                    return
                }
                if let targetUserIds = data.targetUserIds,
                   let currentUserId = mlsClient.userId,
                   !targetUserIds.contains(currentUserId) {
                    log.debug("[E2eSync] Skipping welcome not targeted at current user", subsystems: .mls)
                    return
                }
                log.debug("[MLS] Handle welcome event of cid: \(cidString)", subsystems: .mls)
                if let welcome = data.welcome, let tree = data.ratchetTree,
                   let ratchetTree = try? RatchetTree.fromBytes(data: Data(tree)) {
                    try mlsClient.joinWithWelcome(cid: cidString, welcome: Data(welcome), ratchetTree: ratchetTree)
                    saveMlsGroupJoinedAt(cidString: cidString)
                }
            case .proposal:
                break
//                if let proposal = data.proposal {
//                    try mlsClient.processMessage(data: Data(proposal), in: cidString)
//                }
            }
        } catch {
            log.error("[E2eSync] Failed to apply protocol event (type=\(data.type)): \(error)", subsystems: .mls)
        }
    }

    private func saveSyncCursors(_ cursors: [String: Int64]) {
        saveE2eSyncCursorsToUserDefaults(cursors)
    }

    /// Records the current timestamp as the moment this device joined the MLS group for the given channel.
    /// Called after a successful external join or welcome-based join.
    private func saveMlsGroupJoinedAt(cidString: String) {
        database.write { session in
            guard let cid = try? ChannelId(cid: cidString),
                  let dto = session.channel(cid: cid) else { return }
            dto.mlsGroupJoinedAt = Date().bridgeDate
        } completion: { error in
            if let error {
                log.error("[E2eSync] Failed to save mlsGroupJoinedAt for \(cidString): \(error)", subsystems: .mls)
            }
        }
    }

    func consumeKeyPackages(in cid: ChannelId, targetUserIds: [String], completion: @escaping (Result<[KeyPackage], Error>) -> Void) {
        apiClient.request(endpoint: .consumeKeyPackages(cid: cid, targetUserIds: targetUserIds), completion: { result in
            switch result {
            case .success(let payload):
                let memberKeyPackages = payload.members.reduce(into: [[UInt8]]()) { result, memberPackage in
                    let keyPackages = memberPackage.keyPackages.map({ $0.keyPackage})
                    result.append(contentsOf: keyPackages)
                }

                do {
                    let keyPackages = try memberKeyPackages.map { bytes in
                        try KeyPackage.fromBytes(data: Data(bytes))
                    }
                    completion(.success(keyPackages))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                log.error("Failed to comsume key in channel: \(cid) with error: \(error)")
                completion(.failure(error))
            }
        })
    }

    func consumeKeyPackagesBatch(targetUserIds: [String], completion: @escaping (Result<[KeyPackage], Error>) -> Void) {
        apiClient.request(endpoint: .consumeKeyPackagesBatch(userIds: targetUserIds), completion: { result in
            switch result {
            case .success(let payload):
                let memberKeyPackages = payload.members.reduce(into: [[UInt8]]()) { result, memberPackage in
                    let keyPackages = memberPackage.keyPackages.map({ $0.keyPackage})
                    result.append(contentsOf: keyPackages)
                }

                do {
                    let keyPackages = try memberKeyPackages.map { bytes in
                        try KeyPackage.fromBytes(data: Data(bytes))
                    }
                    completion(.success(keyPackages))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                log.error("Failed to comsume key package of user: \(targetUserIds) with error: \(error)")
                completion(.failure(error))
            }
        })
    }

    func addMember(to cid: ChannelId, memberKeypackages: [KeyPackage]) throws -> (CommitBundle, RatchetTree, Data, Int) {
        let group = try mlsClient.loadOrCreateGroup(with: cid.rawValue)
        let commitBundle = try mlsClient.addMember(to: group, memberKeyPackages: memberKeypackages)
        
        let ratchetTree = group.exportRatchetTree()
        
        guard let groupInfo = commitBundle.groupInfo else {
            throw ClientError("[MLS] add member failed, no group info in commit bundle")
        }
        let epoch = Int(group.epoch())
        log.debug("TTTTTTTT ADD MEMBER CURRENT EPOCH: \(epoch)")
        return (commitBundle, ratchetTree, groupInfo, epoch)
    }

    func removeMembers(_ userIds: [String], in cid: ChannelId) throws -> (CommitBundle, Data, Int) {
        let group = try mlsClient.loadGroup(with: cid.rawValue)
        let commitBunddle = try mlsClient.removeMembers(userIds, in: group)
        guard let groupInfo = commitBunddle.groupInfo else {
            throw ClientError("[MLS] Remove member failed, no group info in commit bundle")
        }//try mlsClient.exportGroupInfo(of: group)
        let epoch = Int(group.epoch())
        log.debug("TTTTTTTT REMOVE MEMBER CURRENT EPOCH: \(epoch)")
        return (commitBunddle, groupInfo, epoch)
    }

    func externalJoinChannel(cid: ChannelId, completion: @escaping (Error?) -> Void) {
        apiClient.request(endpoint: .getGroupInfo(cid: cid)) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let groupInfo):
                guard !groupInfo.isStale else {
                    completion(ClientError("Group info is stable, retry later."))
                    return
                }
                do {
                    let externalJoinResult = try mlsClient.externalJoin(groupInfo: groupInfo.groupInfo.data)
                    log.debug("External join group with cid: \(cid) info: \(externalJoinResult.group.epoch())", subsystems: .mls)
                    requestExternalJoin(to: cid, externalJoinResult: externalJoinResult, completion: completion)
                } catch (let error) {
                    completion(ClientError("Group info is stable, retry later."))
                    return
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    private func requestExternalJoin(to cid: ChannelId, externalJoinResult: ExternalJoinResult, completion: @escaping (Error?) -> Void) {
        let body = ExternalJoinRequestBody(commit: externalJoinResult.commit,
                                           epoch: Int(externalJoinResult.group.epoch()),
                                           projectId: cid.projectId)
        apiClient.request(endpoint: .externalJoin(cid: cid, body: body)) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let payload):
                do {
                    try mlsClient.mergePendingCommit(in: cid)
                    saveMlsGroupJoinedAt(cidString: cid.rawValue)
                    let group = externalJoinResult.group
                    let groupInfo = try mlsClient.exportGroupInfo(of: group)
                    let epoch = group.epoch()
                    uploadGroupInfo(in: cid, groupInfo: groupInfo, epoch: Int(epoch), completion: completion)
                } catch (let error) {
                    completion(error)
                }
            case .failure(let error):
                try? mlsClient.clearPendingCommit(in: cid)
                completion(error)
            }
        }
    }

    private func uploadGroupInfo(in cid: ChannelId, groupInfo: Data, epoch: Int, completion: @escaping (Error?) -> Void) {
        let body = UploadGroupInfoRequestBody(groupInfo: groupInfo,
                                              epoch: epoch)
        apiClient.request(endpoint: .uploadGroupInfo(cid: cid, body: body)) { [weak self] result in
            switch result {
            case .success:
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    func encryptedMessage(_ message: E2ePayload, in cid: ChannelId) throws -> ([UInt8], Int) {
        let group = try mlsClient.loadGroup(with: cid.rawValue)
        let data = try JSONEncoder().encode(message)
        let encryptedData = try mlsClient.encrypt(inputData: data, in: group)
        let epoch = Int(group.epoch())
        return (encryptedData.uint8Array, epoch)
    }

    func mergePendingCommit(in cid: ChannelId) throws {
        try mlsClient.mergePendingCommit(in: cid)
    }

    func clearPendingCommit(in cid: ChannelId) throws {
        try mlsClient.clearPendingCommit(in: cid)
    }

    func commitPendingProposal(in cid: ChannelId) throws {
        try mlsClient.commitPendingProposal(in: cid)
    }

    /// Returns `true` when we should skip a welcome message for the given channel.
    /// A welcome is skipped only when the group already exists locally **and** the
    /// current user is an active member (i.e. the channel exists in the DB with a
    /// role that is NOT `pending` or `rejected`).
    ///
    /// Returns `false` (= process the welcome) when:
    /// - The group is not loaded yet, OR
    /// - The group is loaded but the channel doesn't exist in the DB, OR
    /// - The group is loaded, the channel exists, but the member role is `pending` or `rejected`
    ///   (user was kicked and re-added — the old MLS group is stale).
    private func shouldSkipWelcome(cid cidString: String) -> Bool {
        guard mlsClient.isGroupLoaded(cid: cidString) else {
            return false
        }
        return true
    }

    func clearPendingProposal(in cid: ChannelId) throws {
        try mlsClient.clearPendingProposal(in: cid)
    }

    public func reset() {
        loginTime = nil
        finishSync()
        do {
            try mlsClient.reset()
        } catch (let error) {
            log.error("[MLS] Failed to reset MLS: \(error)", subsystems: .mls)
        }
    }
    
    public func deleteGroup(cid: String) throws {
        try mlsClient.deleteGroup(cid: cid)
        removeE2eSyncCursor(for: cid)
    }

    // MARK: - Decryption

    /// The single decryption gate for all message sources (WebSocket, API, NSE).
    ///
    /// Enqueues work onto the serial `decryptQueue` so MLS `processMessage` is
    /// never called concurrently. Inside the queue the database is consulted first;
    /// if another operation has already written the cache the MLS call is skipped.
    ///
    /// - Parameters:
    ///   - messageId: The ID of the message to decrypt.
    ///   - encryptedData: The raw MLS ciphertext bytes stored on the message.
    ///   - cid: The channel the message belongs to (used to look up the MLS group).
    ///   - completion: Called with the decrypted `E2ePayload` or an error.
    ///                 Always invoked, even on cache hits.
    func decryptMessagePayload(
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        completion: ((_ result: Result<E2ePayload, Error>) -> Void)? = nil
    ) {
        decryptQueue.addOperation { [weak self] in
            guard let self else { return }
            self.decryptMessagePayloadSync(
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                completion: completion
            )
        }
    }

    /// Decrypts an encrypted `ChatMessage`, using the cached decrypted payload when available.
    ///
    /// Routes through `decryptMessagePayload` so the serial queue is always respected,
    /// regardless of which source triggered the call.
    ///
    /// - Parameters:
    ///   - message: The `ChatMessage` to decrypt. Must have `encryptedData` set.
    ///   - completion: Called with the updated `ChatMessage` or an error.
    func decryptMessage(
        _ message: ChatMessage,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {

        log.debug("[MLS] Current message epoch: \(message.mlsEpoch)", subsystems: .mls)
        // Fast path: already cached on the model (loaded from DB at fetch time).
        if let cached = message.decryptedMessage {
            var updated = message
            updated.text = cached.text
            updated.stickerUrl = cached.stickerUrl
            completion(.success(updated))
            return
        }

        guard let encryptedData = message.encryptedData else {
            completion(.failure(ClientError.Unexpected("Message has no encrypted data.")))
            log.error("Failed to decrypted message: no encrypted data", subsystems: .mls)
            return
        }
        guard let cid = message.cid else {
            completion(.failure(ClientError.Unexpected("Message has no channel id for decryption.")))
            log.error("Failed to decrypted message: no channel id", subsystems: .mls)
            return
        }

        decryptMessagePayload(messageId: message.id, encryptedData: encryptedData, cid: cid) { result in
            switch result {
            case .success(let payload):
                var updated = message
                updated.text = payload.text
                updated.stickerUrl = payload.stickerUrl
                updated.decryptedMessage = payload
                completion(.success(updated))
            case .failure(let error):
                completion(.failure(error))
                log.error("Failed to decrypted message: \(error)", subsystems: .mls)
            }
        }
    }
}
