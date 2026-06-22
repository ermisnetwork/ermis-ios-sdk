//
// Copyright 2025 Ermis Inc.
//

import Foundation
import open_mls_ios
import CoreData

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
    
    /// Returns the saved composite sync cursor (`{created_at, event_id}`) for a channel/scope,
    /// or nil if none is stored. Scoped by the current userId so cursors from different users
    /// don't interfere. A legacy millisecond cursor (from before the scope_sync migration) is
    /// transparently upgraded to a composite cursor with the all-zero event id.
    private func e2eSyncCursor(for channelId: String) -> ScopeSyncCursorPayload? {
        guard let userId = mlsClient.userId else { return nil }
        guard let userCursors = UserDefaults.standard.dictionary(forKey: MlsClient.cursorKey)?[userId] as? [String: Any],
              let raw = userCursors[channelId] else { return nil }
        if let dict = raw as? [String: String],
           let createdAt = dict["created_at"], let eventId = dict["event_id"] {
            return ScopeSyncCursorPayload(createdAt: createdAt, eventId: eventId)
        }
        // Backward-compat: migrate a legacy millisecond cursor to a composite cursor.
        if let ms = (raw as? NSNumber)?.int64Value {
            return Self.cursor(fromMilliseconds: ms)
        }
        return nil
    }

    /// Saves composite sync cursors for the given channels/scopes into UserDefaults.
    /// Scoped by the current userId so cursors from different users don't interfere.
    private func saveE2eSyncCursorsToUserDefaults(_ cursors: [String: ScopeSyncCursorPayload]) {
        guard let userId = mlsClient.userId else { return }
        var all = UserDefaults.standard.dictionary(forKey: MlsClient.cursorKey) ?? [:]
        var userCursors = all[userId] as? [String: Any] ?? [:]
        for (cid, cursor) in cursors {
            userCursors[cid] = ["created_at": cursor.createdAt, "event_id": cursor.eventId]
        }
        all[userId] = userCursors
        UserDefaults.standard.set(all, forKey: MlsClient.cursorKey)
    }

    /// Removes the sync cursor for a given channel ID from UserDefaults.
    /// Called when an MLS group is deleted so the stale cursor doesn't persist.
    private func removeE2eSyncCursor(for channelId: String) {
        guard let userId = mlsClient.userId else { return }
        var all = UserDefaults.standard.dictionary(forKey: MlsClient.cursorKey) ?? [:]
        var userCursors = all[userId] as? [String: Any] ?? [:]
        userCursors.removeValue(forKey: channelId)
        all[userId] = userCursors
        UserDefaults.standard.set(all, forKey: MlsClient.cursorKey)
    }

    /// Advances the sync cursor for a channel to "now" (with the all-zero event id).
    ///
    /// Called when the local MLS group is deleted because of a removal / self-leave.
    /// Per the E2EE sync contract, a removed/self-left device must ADVANCE the cursor —
    /// NOT clear it. If the cursor is cleared, a later re-add/re-invite has no saved
    /// cursor, so `resolveSyncCursor` falls back to `memberCreatedAt`/`mlsGroupJoinedAt`,
    /// which the server keeps at the ORIGINAL membership time. The sync then replays the
    /// original Welcome, whose KeyPackage was already consumed, and `joinWithWelcome`
    /// fails with `NoMatchingKeyPackage` — leaving the re-joined user unable to decrypt.
    /// Pinning the cursor to the leave time makes the next sync fetch only the NEW Welcome.
    private func advanceE2eSyncCursor(for channelId: String) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveE2eSyncCursorsToUserDefaults([channelId: Self.cursor(fromMilliseconds: nowMs)])
    }

    /// The all-zero event id used as the tie-breaker for cursors that have no server event id
    /// (boundary cursors derived from membership/join time, or cursors advanced to "now").
    private static let zeroEventId = "00000000-0000-0000-0000-000000000000"

    /// Builds a composite cursor from a millisecond timestamp, using the all-zero event id.
    private static func cursor(fromMilliseconds ms: Int64) -> ScopeSyncCursorPayload {
        ScopeSyncCursorPayload(createdAt: rfc3339String(fromMilliseconds: ms), eventId: zeroEventId)
    }

    /// Converts milliseconds since epoch to an RFC3339 string with millisecond precision
    /// (e.g. "2026-05-17T10:00:00.755Z"). Millisecond is the true resolution of the `Int64`
    /// input, and this exact `.SSS` shape round-trips through `parseRemovedAt`, which the
    /// kick/re-add detection in `resolveSyncCursor` relies on.
    private static func rfc3339String(fromMilliseconds ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            components.year!, components.month!, components.day!,
            components.hour!, components.minute!, components.second!,
            Int(ms % 1000)
        )
    }

    /// UserDefaults key for the user-scoped `removed_channels` sync cursor.
    private static let removedCursorKey = "ermis_e2e_removed_cursor"

    /// Loads the saved `removed_channels` cursor for the current user, or nil on first sync.
    /// Scoped by userId so cursors from different users don't interfere.
    private func loadRemovedSyncCursor() -> RemovedSyncCursorPayload? {
        guard let userId = mlsClient.userId else { return nil }
        let all = UserDefaults.standard.dictionary(forKey: Self.removedCursorKey) as? [String: [String: String]]
        guard let dict = all?[userId],
              let removedAt = dict["removed_at"],
              let eventId = dict["event_id"] else { return nil }
        return RemovedSyncCursorPayload(removedAt: removedAt, eventId: eventId)
    }

    /// Persists the `removed_channels` cursor for the current user. Stored as RFC3339
    /// strings so sub-millisecond precision in `removed_at` is preserved.
    private func saveRemovedSyncCursor(_ cursor: RemovedSyncCursorPayload) {
        guard let userId = mlsClient.userId else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.removedCursorKey) as? [String: [String: String]] ?? [:]
        all[userId] = ["removed_at": cursor.removedAt, "event_id": cursor.eventId]
        UserDefaults.standard.set(all, forKey: Self.removedCursorKey)
    }

    /// Returns `true` when a `removed_channels` event is STALE — i.e. the current user has
    /// already RE-JOINED this channel after the removal happened, so the removal must NOT
    /// trigger local cleanup.
    ///
    /// Without this guard, a self-leave-then-re-add replays the earlier self-leave tombstone
    /// (the `removed_channels` stream is user-scoped history) and deletes the freshly
    /// re-joined MLS group, leaving the user permanently unable to decrypt. The boundary is
    /// `mlsGroupJoinedAt`, which is stamped on every Welcome / external join.
    ///
    /// `channel_deleted` removals can never be re-joined, so they are never treated as stale.
    private func isRemovalStale(cidString: String, removedAt removedAtString: String?, removalType: String?) -> Bool {
        guard removalType != "channel_deleted" else { return false }
        guard let removedAtString,
              let removedAt = Self.parseRemovedAt(removedAtString),
              let cid = try? ChannelId(cid: cidString) else { return false }

        var joinedAt: Date?
        database.viewContext.performAndWait {
            joinedAt = ChannelDTO.load(cid: cid, context: database.viewContext)?.mlsGroupJoinedAt?.bridgeDate
        }
        guard let joinedAt else { return false }
        // Re-joined strictly after the removal → this removal predates the current group.
        return joinedAt > removedAt
    }

    /// Parses an RFC3339 `removed_at` string (with or without fractional seconds) to a `Date`.
    private static func parseRemovedAt(_ string: String) -> Date? {
        if let date = DateFormatter.Ermis.rfc3339Date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
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

    /// Per-channel sync requests that arrived while another sync was already running. Instead of
    /// dropping them (which left a freshly accepted/received channel un-synced until the next
    /// channel-list save), they are drained in `finishSync` as soon as the current sync ends.
    /// Guarded by `syncLock`.
    private var pendingChannelSyncCids: Set<String> = []

    /// Throttle for the full multi-channel sync. `performE2eSync()` is triggered on every
    /// channel-list save (each pagination page, every reconnect, every foreground resync),
    /// and each run does a full DB scan + network round-trip. The throttle runs the leading
    /// call immediately and coalesces a burst of follow-ups into a single trailing run, so
    /// e.g. scrolling the channel list doesn't kick off one full sync per page.
    private let syncThrottleInterval: TimeInterval = 2.0
    private let syncThrottleQueue = DispatchQueue(label: "io.ermis.e2e.sync-throttle")
    private var lastSyncTriggeredAt: Date?
    private var pendingSyncWorkItem: DispatchWorkItem?

    /// Last enqueued group-mutating operation per channel, across *all* sources (realtime
    /// commits/welcomes from `handleMlsEvent` and bulk-sync events from `processE2eSyncEvents`).
    /// `decryptQueue` is serial but `OperationQueue` does not guarantee FIFO dequeue order for
    /// operations of equal priority — and a high-priority realtime commit can overtake a queued
    /// low-priority sync commit. Both would advance the MLS epoch out of order, tripping the
    /// epoch guard and dropping commits. Chaining each op to the previous one for the same
    /// channel via `addDependency` enforces strict per-channel ordering regardless of queue
    /// scheduling; priority still governs ordering *across* channels.
    private var lastOpByCid: [String: Operation] = [:]
    private let lastOpLock = NSLock()

    /// Dedicated private-queue context for E2EE decrypt reads (decrypt cache + pending-message
    /// lookups). Kept separate from `backgroundReadOnlyContext` — which the synchronous
    /// send/encrypt path blocks via `waitUntilFinished` — so a decrypt running on `decryptQueue`
    /// can never deadlock against an in-flight send, while still keeping reads off the main thread.
    private lazy var e2eReadContext: NSManagedObjectContext = {
        let context = database.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }()
    
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
        } else if let event = event as? MessageUpdatedEvent {
            decryptUpdatedMessageEventIfNeeded(message: event.message, cid: event.cid)
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
        // The invite-accept flow doesn't mint an MLS Welcome for the accepting user, so a
        // sync alone may not join them. If the group still isn't present shortly after
        // (no Welcome arrived), join via external commit — which retries while group_info
        // is stale.
        scheduleExternalJoinIfNeeded(cid: event.cid)
    }

    /// After a short delay (enough for a sync / realtime Welcome to land), external-joins
    /// `cid` if the local MLS group still doesn't exist. Used by the invite-accept flow,
    /// which produces no Welcome of its own.
    private func scheduleExternalJoinIfNeeded(cid: ChannelId, delay: TimeInterval = 3.0) {
//        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
//            guard let self else { return }
//            guard !mlsClient.isGroupLoaded(cid: cid.rawValue) else { return }
//            log.debug("[E2E] No local group for \(cid) after invite accept; performing external join", subsystems: .mls)
//            externalJoinChannel(cid: cid) { error in
//                if let error {
//                    log.error("[E2E] External join after invite accept failed for \(cid): \(error)", subsystems: .mls)
//                }
//            }
//        }
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
        let targetUserId = event.member.userId
        let cidString = event.cid.rawValue

        // Current user was removed (or self-left) → delete local MLS group.
        if targetUserId == mlsClient.userId {
            guard mlsClient.isGroupLoaded(cid: cidString) else { return }
            do {
                log.debug("[MLS] Current user removed from channel, deleting MLS group for \(event.cid)", subsystems: .mls)
                try deleteGroup(cid: cidString)
                try deleteGroups(cids: event.topicCids.map { $0.rawValue })
            } catch {
                log.error("[MLS] Failed to delete MLS group after removal: \(error)", subsystems: .mls)
            }
            return
        }

        // Admin kick already has an MLS commit in the standard remove flow → no extra cleanup.
        guard event.isSelfLeave else { return }

        // Another user self-left → queue ghost cleanup.
        database.write { session in
            session.savePendingRemoveMember(userId: targetUserId, channelCid: cidString)
        }
        log.debug("[E2E] Saved pending eviction for self-left member \(targetUserId) in channel \(cidString)", subsystems: .mls)

        // Designated evictor performs actual MLS removal.
        if isDesignatedEvictor(cid: event.cid) {
            commitEviction(cid: event.cid, targetUserIds: [targetUserId])
        }
    }
    
    private func handleMlsEvent(_ mlsEvent: MLSEvent) {
        let mlsProtocol = mlsEvent.mlsProtocol
        let cid = mlsEvent.cid.rawValue
        if let deviceId = mlsProtocol.deviceId, let currentDeviceId = mlsClient.currentDeviceId, deviceId == currentDeviceId {
            log.debug("[MLS] ignored event from self", subsystems: .mls)
            return
        }
        let op = BlockOperation { [weak self] in
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
                    // Epoch advanced — re-attempt any messages that arrived before this commit.
                    self.reDecryptPendingMessages(in: mlsEvent.cid)
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
                    // Epoch advanced — re-attempt any messages that arrived before this commit.
                    self.reDecryptPendingMessages(in: mlsEvent.cid)
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
                    // Group now exists locally — decrypt any messages buffered before the join.
                    self.reDecryptPendingMessages(in: mlsEvent.cid)
                case .proposal:
                    break
                }
            } catch {
                log.error("[MLS] Failed to process event: \(mlsEvent)", subsystems: .mls)
            }
        }
        // Realtime protocol messages unblock decryption — prioritise them over bulk sync.
        // Chained per channel so commits/welcomes advance the epoch in arrival order and never
        // overtake an in-flight sync op for the same group (see `enqueueGroupOperation`).
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: cid)
    }

    /// Enqueues a group-state–mutating operation onto the serial `decryptQueue`, chained after
    /// the previous such operation for the same channel so per-channel MLS work (commits,
    /// welcomes, sync events) runs in enqueue order. Required because `OperationQueue` does not
    /// guarantee FIFO ordering for equal-priority operations, and a `.high` realtime commit must
    /// not overtake a `.low` sync commit for the same group — either would advance the epoch out
    /// of order. `queuePriority` still governs ordering across *different* channels.
    private func enqueueGroupOperation(_ op: Operation, cidString: String) {
        lastOpLock.lock()
        if let previous = lastOpByCid[cidString], !previous.isFinished {
            op.addDependency(previous)
        }
        lastOpByCid[cidString] = op
        lastOpLock.unlock()
        decryptQueue.addOperation(op)
    }
    
    private func decryptNewMessageEventIfNeeded(message: ChatMessage, cid: ChannelId) {
        log.debug("[MLS] Decrypt message with epoch: \(message.mlsEpoch)")
        guard let encryptedData = message.encryptedData else { return }
        decryptMessagePayload(messageId: message.id, encryptedData: encryptedData, cid: cid)
    }
    
    private func decryptUpdatedMessageEventIfNeeded(message: ChatMessage, cid: ChannelId) {
        guard let encryptedData = message.encryptedData else { return }
        // Skip re-decryption for the current user's own edits — the local
        // MessageDecryptDTO was already updated in MessageUpdater.editMessage().
        // MLS cannot decrypt ciphertext produced by the same device.
        if message.isSentByCurrentUser { return }
        log.debug("[MLS] Re-decrypt updated message \(message.id) with epoch: \(message.mlsEpoch)")
        reDecryptUpdatedMessage(messageId: message.id, encryptedData: encryptedData, cid: cid)
    }

    /// Re-decrypts a message after a `message.updated` event WITHOUT discarding the existing
    /// decrypted cache up front.
    ///
    /// An MLS application message can only be decrypted once — the ratchet secret is deleted on
    /// first use (forward secrecy). A `message.updated` event, however, does NOT always carry new
    /// ciphertext: reactions, pins, read receipts and plain re-deliveries (over WebSocket *and*
    /// the E2E sync) all re-emit the message with its *original*, already-consumed ciphertext.
    /// The previous implementation deleted the decrypted cache and re-decrypted that unchanged
    /// ciphertext, which is guaranteed to fail — flipping an already-readable message back to the
    /// "Message is encrypted" placeholder. This is the "see the message, then it changes to
    /// undecrypted" report.
    ///
    /// Strategy: attempt a fresh MLS decrypt that bypasses the cache; overwrite the cache only on
    /// success (a genuine edit produces new, decryptable ciphertext). On failure, leave the
    /// existing cache untouched so the message keeps showing its decrypted content.
    /// Must run on `decryptQueue`.
    private func reDecryptUpdatedMessageSync(messageId: MessageId, encryptedData: Data, cid: ChannelId) {
        do {
            let group = try mlsClient.loadGroup(with: mlsGroupCid(for: cid).rawValue)
            let payload = try mlsClient.decrypt(data: encryptedData, in: group)
            database.write { session in
                try session.saveMessageDecrypt(payload: payload, messageId: messageId)
                session.message(id: messageId)?.text = payload.text
            } completion: { error in
                if let error {
                    log.error("Failed to save re-decrypted message cache for \(messageId): \(error)", subsystems: .mls)
                }
            }
        } catch {
            // Unchanged/already-consumed ciphertext (a non-edit update) or an own-device message:
            // keep the existing decrypted cache rather than regressing to the placeholder.
            log.debug("[MLS] Skipping re-decrypt of updated message \(messageId) (likely unchanged ciphertext): \(error)", subsystems: .mls)
        }
    }

    /// Enqueues `reDecryptUpdatedMessageSync` on the serial `decryptQueue`. Used by the WebSocket
    /// `message.updated` path, which is not already running on `decryptQueue`.
    private func reDecryptUpdatedMessage(messageId: MessageId, encryptedData: Data, cid: ChannelId) {
        let op = BlockOperation { [weak self] in
            self?.reDecryptUpdatedMessageSync(messageId: messageId, encryptedData: encryptedData, cid: cid)
        }
        op.queuePriority = .high
        decryptQueue.addOperation(op)
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
    
    func hashChannelId(projectId: String, userIds: [String]) -> ChannelId {
        let cidString = mlsClient.getChannelId(projectId: projectId, userIds: userIds)
        return ChannelId(type: .messaging, id: cidString)
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
    private func resolveSyncCursor(cidString: String, mlsJoinedAt: NSDate?, memberCreatedAt: NSDate?, deviceLoginTime: Date?) -> ScopeSyncCursorPayload? {
        // 1. Check UserDefaults for an existing sync cursor.
        if let savedCursor = e2eSyncCursor(for: cidString) {
            if let memberCreatedAt,
               let savedDate = Self.parseRemovedAt(savedCursor.createdAt),
               memberCreatedAt.timeIntervalSince1970 > savedDate.timeIntervalSince1970 {
                // Kicked then re-added: membership is newer than the saved cursor. Drop the
                // stale local group and restart from the new membership boundary.
                if (try? mlsClient.loadGroup(with: cidString)) != nil {
                    do {
                        try mlsClient.deleteGroup(cid: cidString)
                    } catch {
                        log.error("[MLS] Remove group: \(cidString) that user has been kick failed with error \(error)", subsystems: .mls)
                    }
                }
                return Self.cursor(fromMilliseconds: Int64(memberCreatedAt.timeIntervalSince1970 * 1000))
            }
            return savedCursor
        }
        //        // 2. Fall back to memberCreatedAt from Core Data.
        if let anchor = mlsJoinedAt {
            return Self.cursor(fromMilliseconds: Int64(anchor.timeIntervalSince1970 * 1000))
        }
        // 3. If the user joined on another device after this device logged in, use loginTime.
        if let loginTime = deviceLoginTime,
           let memberCreatedAt = memberCreatedAt as? Date,
           memberCreatedAt > loginTime {
            return Self.cursor(fromMilliseconds: Int64(loginTime.timeIntervalSince1970 * 1000))
        }

        if let memberCreatedAt {
            return Self.cursor(fromMilliseconds: Int64(memberCreatedAt.timeIntervalSince1970 * 1000))
        }
        return nil
    }
    
    /// Throttled entry point. Runs the leading call right away and coalesces a burst of
    /// follow-up triggers (pagination pages, repeated foreground/reconnect resyncs) into a
    /// single trailing run, instead of starting a full sync per trigger.
    func performE2eSync() {
        syncThrottleQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastSyncTriggeredAt {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < self.syncThrottleInterval {
                    // Within the throttle window — schedule one trailing run (coalesce).
                    guard self.pendingSyncWorkItem == nil else { return }
                    let item = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.pendingSyncWorkItem = nil
                        self.lastSyncTriggeredAt = Date()
                        self.performE2eSyncNow()
                    }
                    self.pendingSyncWorkItem = item
                    self.syncThrottleQueue.asyncAfter(
                        deadline: .now() + (self.syncThrottleInterval - elapsed),
                        execute: item
                    )
                    return
                }
            }
            self.lastSyncTriggeredAt = now
            self.performE2eSyncNow()
        }
    }

    /// Fetches all missed E2EE events for every MLS-enabled channel since the last known cursor,
    /// applying protocol messages and decrypting application messages in order.
    private func performE2eSyncNow() {
        syncLock.lock()
        guard !isSyncing else {
            syncLock.unlock()
            log.debug("[E2eSync] Skipping sync — another sync is already in progress", subsystems: .mls)
            return
        }
        isSyncing = true
        syncLock.unlock()
        
        var cursors: [String: ScopeSyncCursorPayload] = [:]
        let deviceLoginTime = loginTime
        // Resolve cursors on a background context — this scans all MLS channels (and may touch
        // MLS storage in `resolveSyncCursor`), which must not run on the main thread.
        let context = database.backgroundReadOnlyContext
        context.performAndWait {
            let channels = ChannelDTO.fetchAllJoinedMlsEnabled(context: context)
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
        runSync(forCidStrings: [cid.rawValue])
    }

    /// Runs an E2EE sync for a specific set of channels. If a sync is already in flight the
    /// requested channels are queued (`pendingChannelSyncCids`) and drained in `finishSync`, so a
    /// freshly accepted/received channel is synced as soon as the current sync ends instead of
    /// being dropped. Cursor resolution runs on a background context to avoid blocking the UI.
    private func runSync(forCidStrings cidStrings: Set<String>) {
        guard !cidStrings.isEmpty else { return }
        syncLock.lock()
        if isSyncing {
            pendingChannelSyncCids.formUnion(cidStrings)
            syncLock.unlock()
            log.debug("[E2eSync] Queued single-channel sync for \(cidStrings) — another sync is already in progress", subsystems: .mls)
            return
        }
        isSyncing = true
        syncLock.unlock()

        var cursors: [String: ScopeSyncCursorPayload] = [:]
        let deviceLoginTime = loginTime
        let context = database.backgroundReadOnlyContext
        context.performAndWait {
            for cidString in cidStrings {
                guard let cid = try? ChannelId(cid: cidString),
                      let dto = ChannelDTO.load(cid: cid, context: context) else { continue }
                if let cursor = self.resolveSyncCursor(
                    cidString: cidString,
                    mlsJoinedAt: dto.mlsGroupJoinedAt,
                    memberCreatedAt: dto.membership?.memberCreatedAt,
                    deviceLoginTime: deviceLoginTime
                ) {
                    cursors[cidString] = cursor
                }
            }
        }

        guard !cursors.isEmpty else {
            finishSync()
            log.debug("[E2eSync] Skipping sync for \(cidStrings): device has not joined the MLS group yet", subsystems: .mls)
            return
        }
        log.debug("[E2eSync] Starting sync for \(cursors.count) channel(s)", subsystems: .mls)
        syncPage(cursors: cursors)
    }

    private func syncPage(cursors: [String: ScopeSyncCursorPayload]) {
        let body = E2eSyncRequestBody(cursors: cursors, removedCursor: loadRemovedSyncCursor())
        apiClient.request(endpoint: .e2eSync(body: body)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                log.error("[E2eSync] Request failed: \(error)", subsystems: .mls)
                self.finishSync()
            case .success(let payload):
                var nextCursors: [String: ScopeSyncCursorPayload] = [:]

                for (cidString, channelPayload) in payload.channels {
                    // Advance to the server's composite next_cursor (authoritative). Echoing it
                    // back verbatim is what makes same-timestamp events never skip or replay.
                    if let next = channelPayload.nextCursor {
                        nextCursors[cidString] = next
                    }

                    guard !channelPayload.events.isEmpty else { continue }

                    guard let cid = try? ChannelId(cid: cidString) else {
                        log.warning("[E2eSync] Skipping unknown scope cid '\(cidString)'", subsystems: .mls)
                        continue
                    }

                    // Process this scope's events in server order on the serial decryptQueue.
                    // The server already returns only events after the cursor, and the handlers
                    // are idempotent (epoch-guarded commits, skip-if-exists welcomes, decrypt
                    // cache hits, metadata upserts), so no extra client-side filtering is needed.
                    self.processE2eSyncEvents(channelPayload.events, cid: cid, cidString: cidString)

                    // Defensive fallback: if the server omitted next_cursor but sent events,
                    // derive one from the last event so pagination still makes progress.
                    if nextCursors[cidString] == nil, let lastEvent = channelPayload.events.last {
                        nextCursors[cidString] = Self.cursor(fromMilliseconds: Int64(lastEvent.createdAt.timeIntervalSince1970 * 1000))
                    }
                }

                // Persist updated cursors.
                if !nextCursors.isEmpty {
                    self.saveSyncCursors(nextCursors)
                }

                // Apply the user-scoped removed_channels cleanup stream and advance its
                // own cursor. Returns whether more removal pages remain.
                let removedHasMore = self.handleRemovedChannels(payload.removedChannels)

                // Paginate for scopes that still have more events.
                var remaining: [String: ScopeSyncCursorPayload] = [:]
                for (cid, ch) in payload.channels where ch.hasMore {
                    if let next = nextCursors[cid] ?? cursors[cid] {
                        remaining[cid] = next
                    }
                }
                if !remaining.isEmpty || removedHasMore {
                    log.debug("[E2eSync] Paginating for \(remaining.count) scope(s)\(removedHasMore ? " + removed_channels" : "")", subsystems: .mls)
                    self.syncPage(cursors: remaining)
                } else {
                    self.finishSync()
                }
            }
        }
    }
    
    /// Applies the user-scoped `removed_channels` cleanup stream from sync.
    ///
    /// For every channel the current user was removed from (self-leave, kicked, invite
    /// rejected) or that was deleted for everyone (`channel_deleted`), this deletes the
    /// local MLS group + its sync cursor, drops any messages buffered for that group, and
    /// removes the cached channel and its messages from the local DB. The removal cursor
    /// is advanced only AFTER cleanup, so an interrupted run re-delivers the events.
    ///
    /// Deleting the local group here is what lets a later re-add join cleanly via a fresh
    /// Welcome instead of replaying an old Welcome whose KeyPackage was already consumed.
    ///
    /// - Returns: `true` when more removal pages remain (caller should keep paginating).
    @discardableResult
    private func handleRemovedChannels(_ removed: RemovedChannelsPayload?) -> Bool {
        guard let removed else { return false }

        var channelCids: Set<ChannelId> = []
        for event in removed.events {
            let cidString = event.cid

            // Boundary guard: if the current user has already RE-JOINED this channel after
            // this removal happened, the event is a stale tombstone (typically an earlier
            // self-leave) and must NOT delete the freshly re-joined group. The page's removal
            // cursor still advances below, so the tombstone is not re-delivered next sync.
            if isRemovalStale(cidString: cidString, removedAt: event.removedAt, removalType: event.removalType) {
                log.debug("[E2eSync] Skipping stale removal (type=\(event.removalType ?? "unknown")) for \(cidString): re-joined after removed_at=\(event.removedAt ?? "nil")", subsystems: .mls)
                continue
            }

            log.debug("[E2eSync] Channel removed (type=\(event.removalType ?? "unknown")): \(cidString); cleaning local state", subsystems: .mls)

            // Delete the local MLS group and advance (not clear) its sync cursor, so a
            // later re-invite to this channel won't replay the old Welcome. Idempotent —
            // the realtime member.removed handler may already have cleaned it up online.
            do {
                if mlsClient.isGroupLoaded(cid: cidString) {
                    try deleteGroup(cid: cidString)
                } else {
//                    advanceE2eSyncCursor(for: cidString)
                }
                advanceE2eSyncCursor(for: cidString)

            } catch {
                log.error("[E2eSync] Failed to delete MLS group for removed channel \(cidString): \(error)", subsystems: .mls)
            }

            if let cid = try? ChannelId(cid: cidString) {
                channelCids.insert(cid)
            }
        }

        // Remove the cached channels and their messages from local storage.
        if !channelCids.isEmpty {
            database.write { session in
                session.removeChannels(cids: channelCids)
            } completion: { error in
                if let error {
                    log.error("[E2eSync] Failed to remove cached channels after removal: \(error)", subsystems: .mls)
                }
            }
        }

        // Advance the removal cursor only after cleanup has been issued.
        if let next = removed.nextCursor {
            saveRemovedSyncCursor(next)
        }

        return removed.hasMore
    }

    /// Marks the current sync operation as finished so a new one can start, then drains any
    /// per-channel syncs that were requested while this one was running.
    private func finishSync() {
        syncLock.lock()
        isSyncing = false
        let pending = pendingChannelSyncCids
        pendingChannelSyncCids.removeAll()
        syncLock.unlock()

        guard !pending.isEmpty else { return }
        log.debug("[E2eSync] Draining \(pending.count) queued channel sync(s)", subsystems: .mls)
        runSync(forCidStrings: pending)
    }
    
    /// Enqueues each event for one channel onto the serial `decryptQueue` as its own
    /// low-priority operation, in server order.
    ///
    /// Splitting per event (rather than processing the whole channel in one operation) keeps
    /// the queue responsive while a sync is in flight: a high-priority foreground decrypt or a
    /// send only has to wait for the single event currently executing — not the entire
    /// channel's backlog. Per-channel ordering (protocol messages before the application
    /// messages that depend on them) is preserved by chaining each event to the previous one
    /// for the same channel via an operation dependency.
    private func processE2eSyncEvents(_ events: [E2eSyncEventPayload], cid: ChannelId, cidString: String) {
        for event in events {
            let op = BlockOperation { [weak self] in
                self?.processSingleE2eSyncEvent(event, cid: cid, cidString: cidString)
            }
            op.queuePriority = .low
            enqueueGroupOperation(op, cidString: cidString)
        }
    }

    /// Applies a single E2EE sync event. Must run on `decryptQueue`.
    private func processSingleE2eSyncEvent(_ event: E2eSyncEventPayload, cid: ChannelId, cidString: String) {
        switch event {
        case .protocol(let data):
            applyE2eSyncProtocolEvent(data, cidString: cidString)
        case .application(let data):
            if data.isSystemMessage {
                handleSystemMessage(data, cid: cid)
            } else {
                // Call the synchronous body directly — we are already on decryptQueue,
                // so we must NOT re-enqueue via decryptMessagePayload (that would deadlock
                // the serial queue waiting on itself).
                guard let mlsCiphertext = data.mlsCiphertext else {
                    log.error("Missing mls_ciphertext for regular application message \(data.id)")
                    return
                }
                decryptMessagePayloadSync(
                    messageId: data.id,
                    encryptedData: Data(mlsCiphertext),
                    cid: cid
                )
            }
        case .reaction(let data):
            handleReactionSyncEvent(data)
        case .messageDeleted(let data):
            handleMessageDeletedSyncEvent(data)
        case .messageUpdated(let data):
            handleMessageUpdatedSyncEvent(data, cid: cid)
        case .messagePin(let data):
            handleMessagePinSyncEvent(data)
        case .memberRemoved(let data, _):
            handleMemberRemovedSyncEvent(data, cid: cid)
        case .inviteAccepted(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .inviteRejected(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .inviteMessagingRejected(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .inviteMessagingSkipped(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .websocketEvent(let payload):
            handleWebsocketEvent(payload)
        case .unknown(let type, let rawData):
            log.warning("[E2eSync] Unknown sync event type '\(type)' in channel \(cidString), data: \(rawData)", subsystems: .mls)
        }
    }

    /// Handles a websocket event received during E2EE sync by dispatching it
    /// through the standard event processing pipeline.
    private func handleWebsocketEvent(_ payload: EventPayload) {
        do {
            if payload.eventType == .memberRemoved {
                handleMemberRemovedEvent(payload)
                return
            }
//            let event = try payload.event()
//            eventNotificationCenter.process(event)
        } catch {
            log.error("[E2eSync] Failed to process websocket event (type=\(payload.eventType)): \(error)", subsystems: .mls)
        }
    }

    /// Handles a member.removed event received during E2EE sync.
    /// Called on `decryptQueue`.
    /// - Parameter payload: The event payload for the member removal.
    private func handleMemberRemovedEvent(_ payload: EventPayload) {
        do {
            let event = try MemberRemovedEventDTO(from: payload)
            let targetUserId = event.member.userId
            let cidString = event.cid.rawValue

            if targetUserId == mlsClient.userId {
                // Current user was removed → delete local MLS group.
                try deleteGroup(cid: cidString)
                try deleteGroups(cids: event.topicCids.map { $0.rawValue })
                log.debug("[E2E] Deleted local MLS group for \(cidString) after current user removed", subsystems: .mls)
            } else if event.selfRemove == true {
                // Another user self-left → queue ghost cleanup.
                database.write { session in
                    session.savePendingRemoveMember(userId: targetUserId, channelCid: cidString)
                }
                log.debug("[E2E] Saved pending eviction for self-left member \(targetUserId) in channel \(cidString)", subsystems: .mls)

                // Designated evictor performs actual MLS removal.
                if isDesignatedEvictor(cid: event.cid) {
                    commitEviction(cid: event.cid, targetUserIds: [targetUserId])
                }
            }
            // Admin kick: do nothing extra — standard remove flow includes the MLS commit.
        } catch {
            log.error("Failed to handle member remove sync event: \(error)", subsystems: .mls)
        }
    }
    
    // MARK: - Sync Event Handlers

    /// Handles a `reaction` sync event by saving/updating the reaction snapshot in the database.
    /// Called on `decryptQueue`.
    private func handleReactionSyncEvent(_ data: ReactionSyncData) {
        log.debug("[E2eSync] Handling reaction sync event for message \(data.message.id)", subsystems: .mls)
        database.write { session in
            // Save the message first so the reaction has a target
            try session.saveMessage(payload: data.message, for: data.cid, syncOwnReactions: true, cache: nil)
            // Save the reaction (creates or updates)
            try session.saveReaction(payload: data.reaction, cache: nil)
        } completion: { error in
            if let error {
                log.error("[E2eSync] Failed to save reaction sync event: \(error)", subsystems: .mls)
            }
        }
    }

    /// Handles a `message_deleted` sync event by removing the message from local cache.
    /// Called on `decryptQueue`.
    private func handleMessageDeletedSyncEvent(_ data: MessageDeletedSyncData) {
        log.debug("[E2eSync] Handling message_deleted sync event for message \(data.message.id)", subsystems: .mls)
        database.write { session in
            // Save the message payload which includes deletedAt being set
            try session.saveMessage(payload: data.message, for: data.cid, syncOwnReactions: false, cache: nil)
        } completion: { error in
            if let error {
                log.error("[E2eSync] Failed to handle message_deleted sync event: \(error)", subsystems: .mls)
            }
        }
    }

    /// Handles a `message_updated` sync event by decrypting the latest snapshot and upserting it.
    /// Called on `decryptQueue`.
    private func handleMessageUpdatedSyncEvent(_ data: MessageUpdatedSyncData, cid: ChannelId) {
        let messageId = data.message.id
        log.debug("[E2eSync] Handling message_updated sync event for message \(messageId)", subsystems: .mls)

        // Check if the message has encrypted data that may need re-decryption
        if let encryptedBytes = data.message.encryptedData {
            let encryptedData = Data(encryptedBytes)
            // Save the updated message payload. Do NOT delete the decrypted cache here — a
            // `message_updated` sync event is often a non-content change (reaction/pin/read/
            // re-delivery) that carries the original, already-consumed ciphertext; re-decrypting
            // it would fail and regress the message to the "encrypted" placeholder.
            // See reDecryptUpdatedMessageSync.
            database.write { session in
                try session.saveMessage(payload: data.message, for: cid, syncOwnReactions: false, cache: nil)
            } completion: { [weak self] error in
                if let error {
                    log.error("[E2eSync] Failed to save updated message \(messageId): \(error)", subsystems: .mls)
                    return
                }
                // Non-destructive re-decrypt — overwrites the cache only if the (new) ciphertext
                // actually decrypts. Called directly since we are on decryptQueue.
                self?.reDecryptUpdatedMessageSync(
                    messageId: messageId,
                    encryptedData: encryptedData,
                    cid: cid
                )
            }
        } else {
            // No encrypted data — just save the message payload directly
            database.write { session in
                try session.saveMessage(payload: data.message, for: cid, syncOwnReactions: false, cache: nil)
            } completion: { error in
                if let error {
                    log.error("[E2eSync] Failed to save updated message \(messageId): \(error)", subsystems: .mls)
                }
            }
        }
    }

    /// Handles a `message_pin` sync event by patching the pin/unpin state on the message.
    /// Called on `decryptQueue`.
    private func handleMessagePinSyncEvent(_ data: MessagePinSyncData) {
        log.debug("[E2eSync] Handling message_pin sync event for message \(data.message.id)", subsystems: .mls)
        database.write { session in
            // Save the message which includes pin fields (pinnedAt, pinnedBy, pinExpires)
            try session.saveMessage(payload: data.message, for: data.cid, syncOwnReactions: false, cache: nil)
        } completion: { error in
            if let error {
                log.error("[E2eSync] Failed to handle message_pin sync event: \(error)", subsystems: .mls)
            }
        }
    }

    /// Handles a `member_removed` sync event.
    /// If `selfRemove` is true, queues a pending ghost for composite cleanup.
    /// If `selfRemove` is false, treats as admin kick.
    /// Called on `decryptQueue`.
    /// - Parameters:
    ///   - data: The member removal data (member + selfRemove flag).
    ///   - cid: The channel ID from the sync envelope.
    private func handleMemberRemovedSyncEvent(_ data: MemberRemovedSyncData, cid: ChannelId) {
        guard let member = data.memberContainer.member else {
            log.error("[E2eSync] member_removed sync event missing member payload", subsystems: .mls)
            return
        }

        let userId = member.userId
        let cidString = cid.rawValue

        if userId == mlsClient.userId {
            // Current user was removed → delete local MLS group and stop E2EE for this channel.
            do {
                try deleteGroup(cid: cidString)
                log.debug("[E2eSync] Deleted local MLS group for \(cidString) after current user removed via sync", subsystems: .mls)
            } catch {
                log.error("[E2eSync] Failed to delete MLS group after removal via sync: \(error)", subsystems: .mls)
            }
        } else if data.selfRemove {
            // Another member self-removed → queue ghost cleanup.
            database.write { session in
                session.savePendingRemoveMember(userId: userId, channelCid: cidString)
            }
            log.debug("[E2eSync] Saved pending eviction for self-left member \(userId) in channel \(cidString)", subsystems: .mls)

            // Designated evictor performs actual MLS removal.
            if isDesignatedEvictor(cid: cid) {
                commitEviction(cid: cid, targetUserIds: [userId])
            }
        }
        // Admin kick: do nothing extra — standard remove flow includes the MLS commit.
    }

    /// Handles an invite respond-back sync event (accepted, rejected, messaging_rejected, messaging_skipped).
    /// Triggers E2E channel sync when MLS is enabled, matching the websocket event behavior.
    /// Called on `decryptQueue`.
    /// - Parameters:
    ///   - data: The invite respond data (mlsEnabled, member, topicCids).
    ///   - cid: The channel ID from the sync envelope.
    private func handleInviteRespondSyncEvent(_ data: InviteRespondSyncData, cid: ChannelId) {
        guard data.mlsEnabled else { return }
        log.debug("[E2eSync] Handling invite respond sync event for channel \(cid)", subsystems: .mls)
        performE2eChannelSync(cid: cid)
    }

    // MARK: - System Message Handling
    
    /// Handles a system message received during E2EE sync.
    /// Called on `decryptQueue`. System messages are plain-text and do not require MLS decryption.
    /// - Parameters:
    ///   - data: The application event data with `type == .system`.
    ///   - cid: The channel this message belongs to.
    private func handleSystemMessage(_ data: E2eSyncApplicationData, cid: ChannelId) {
        // TODO: Implement system message handling (e.g. persist to DB, update UI).
        log.debug("[E2E] Received system message \(data.id) in \(cid): \(data.text ?? "")", subsystems: .mls)
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
        // Read on the background read-only context so the decrypt hot path never
        // hops to (and blocks on) the main-queue `viewContext`, and never on
        // `backgroundReadOnlyContext` (which a synchronous send may be blocking).
        var cachedPayload: E2ePayload?
        let readContext = e2eReadContext
        readContext.performAndWait {
            if let dto = MessageDecryptDTO.load(messageId: messageId, context: readContext) {
                cachedPayload = try? dto.asPayload()
            }
        }
        
        if let cached = cachedPayload {
            completion?(.success(cached))
            return
        }
        
        // No cache — run MLS decrypt. A topic message is encrypted with its parent
        // channel's MLS group, so resolve the topic cid to the group-owning cid first.
        do {
            let group = try mlsClient.loadGroup(with: mlsGroupCid(for: cid).rawValue)
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

    /// Re-attempts decryption for messages in `cid` that still hold ciphertext but have
    /// no cached plaintext yet. Called after a commit/welcome advances the group epoch so
    /// messages that arrived *before* their epoch's protocol message self-heal, instead of
    /// being stuck on the "encrypted" placeholder until the user leaves and re-opens the
    /// channel. Idempotent: messages already decrypted (cache present) are skipped.
    private func reDecryptPendingMessages(in cid: ChannelId) {
        let context = e2eReadContext
        var pending: [(id: MessageId, data: Data)] = []
        context.performAndWait {
            let request = NSFetchRequest<MessageDTO>(entityName: MessageDTO.entityName)
            request.predicate = NSPredicate(
                format: "cid == %@ AND encryptedData != nil AND decryptedMessage == nil",
                cid.rawValue
            )
            guard let results = try? context.fetch(request) else { return }
            pending = results.compactMap { dto in
                guard let data = dto.encryptedData else { return nil }
                return (dto.id, data)
            }
        }
        guard !pending.isEmpty else { return }
        log.debug("[MLS] Re-decrypting \(pending.count) pending message(s) in \(cid) after epoch advance", subsystems: .mls)
        for item in pending {
            decryptMessagePayload(messageId: item.id, encryptedData: item.data, cid: cid)
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
                    // Epoch advanced — re-attempt messages buffered before this commit.
                    if let cid = try? ChannelId(cid: cidString) {
                        reDecryptPendingMessages(in: cid)
                    }
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
                    do {
                        try mlsClient.joinWithWelcome(cid: cidString, welcome: Data(welcome), ratchetTree: ratchetTree)
                        saveMlsGroupJoinedAt(cidString: cidString)
                        // Group now exists locally — decrypt any messages buffered before the join.
                        if let cid = try? ChannelId(cid: cidString) {
                            reDecryptPendingMessages(in: cid)
                        }
                    } catch {
                        // The Welcome is encrypted for a KeyPackage this device no longer
                        // has — e.g. it was consumed by the user's earlier (pre-leave) join,
                        // or the server served a stale KeyPackage on re-invite — surfacing as
                        // NoMatchingKeyPackage. Recover by joining from the group's GroupInfo
                        // via an external commit, which does not depend on a Welcome /
                        // KeyPackage match. This is the prescribed fallback for a device that
                        // was effectively "not included" in a usable Welcome.
                        log.error("[E2eSync] joinWithWelcome failed for \(cidString) (\(error)); falling back to external join", subsystems: .mls)
                        if !mlsClient.isGroupLoaded(cid: cidString), let cid = try? ChannelId(cid: cidString) {
                            externalJoinChannel(cid: cid) { joinError in
                                if let joinError {
                                    log.error("[E2eSync] External join fallback failed for \(cidString): \(joinError)", subsystems: .mls)
                                }
                            }
                        }
                    }
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
    
    private func saveSyncCursors(_ cursors: [String: ScopeSyncCursorPayload]) {
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

    /// Adds new members while removing pending "ghost" leaves (members who self-left but
    /// whose MLS leaf has not been evicted yet) in a SINGLE composite commit.
    ///
    /// Self-leave does not remove the leaver's MLS leaf — only the designated evictor's
    /// `commit_eviction` does. Until that propagates, the leaf lingers, and a plain
    /// `add_members` fails when that same user is re-added (duplicate leaf) or when the
    /// roster still contains the ghost. Bundling the ghost removals into the add commit
    /// (the self-leave composite-cleanup flow) clears the stale leaves and adds the new
    /// members in one epoch advance.
    func addMembersWithRemovals(to cid: ChannelId, removeUserIds: [String], memberKeypackages: [KeyPackage]) throws -> (CommitBundle, RatchetTree, Data, Int) {
        let (commitBundle, ratchetTree, epoch) = try mlsClient.addMembersWithRemovals(
            in: cid.rawValue,
            removeUserIds: removeUserIds,
            addMembers: memberKeypackages
        )
        guard let groupInfo = commitBundle.groupInfo else {
            throw ClientError("[MLS] add member with removals failed, no group info in commit bundle")
        }
        log.debug("TTTTTTTT ADD MEMBER WITH REMOVALS CURRENT EPOCH: \(epoch), removed ghosts: \(removeUserIds)")
        return (commitBundle, ratchetTree, groupInfo, epoch)
    }

    func removeAllPendingChannel(cids: [String]) {
        
    }
    
    // MARK: - Pending Remove Member

    /// Returns all user IDs that have a pending self-remove in the given channel.
    /// Use this when adding or removing members to check if the channel has pending removals.
    func getPendingRemoveMemberUserIds(channelCid: String) -> [String] {
        var userIds: [String] = []
        database.viewContext.performAndWait {
            userIds = PendingRemoveMemberDTO.loadAll(channelCid: channelCid, context: database.viewContext).map(\.userId)
        }
        return userIds
    }

    /// Checks whether a specific member has a pending self-remove in the given channel.
    func hasPendingRemoveMember(userId: String, channelCid: String) -> Bool {
        var result = false
        database.viewContext.performAndWait {
            result = PendingRemoveMemberDTO.load(userId: userId, channelCid: channelCid, context: database.viewContext) != nil
        }
        return result
    }

    /// Removes a member from the pending remove list after it has been handled.
    func deletePendingRemoveMember(userId: String, channelCid: String) {
        database.write { session in
            session.deletePendingRemoveMember(userId: userId, channelCid: channelCid)
        }
    }

    /// Removes multiple members from the pending remove list after they have been handled.
    func deletePendingRemoveMembers(userIds: [String], channelCid: String) {
        database.write { session in
            session.deletePendingRemoveMembers(userIds: userIds, channelCid: channelCid)
        }
    }

    // MARK: - Commit Eviction

    /// Determines whether the current user is the designated evictor for a channel.
    ///
    /// The designated evictor is the channel owner (creator). Only one member should
    /// perform the MLS ghost cleanup to avoid duplicate commits.
    ///
    /// - Parameter cid: The channel identifier.
    /// - Returns: `true` if the current user is the channel owner and should perform eviction.
    func isDesignatedEvictor(cid: ChannelId) -> Bool {
        guard let currentUserId = mlsClient.userId else { return false }
        var isEvictor = false
        database.viewContext.performAndWait {
            guard let channelDTO = ChannelDTO.load(cid: cid, context: database.viewContext) else { return }
            isEvictor = channelDTO.createdBy?.id == currentUserId
        }
        return isEvictor
    }

    /// Performs an MLS eviction commit to remove ghost members from the MLS group roster.
    ///
    /// Ghost members are users who self-left the channel but whose MLS group membership
    /// has not yet been cleaned up. This method:
    /// 1. Loads the MLS group.
    /// 2. Creates a commit to remove the target users from the MLS roster.
    /// 3. Sends the eviction commit to the server (MLS cleanup only, no membership mutation).
    /// 4. On success: merges the commit and clears the pending eviction queue.
    /// 5. On failure: rolls back the pending commit and persists cleanup.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - targetUserIds: The user IDs of the ghost members to evict from the MLS group.
    func commitEviction(cid: ChannelId, targetUserIds: [String]) {
        guard !targetUserIds.isEmpty else { return }
        let cidString = cid.rawValue

        do {
            // 1. Load current MLS group.
            let group = try mlsClient.loadGroup(with: cidString)

            // 2. Create commit to remove target users from MLS group.
            let commitBundle = try mlsClient.removeMembers(targetUserIds, in: group)

            // 3. Get pre-merge epoch.
            let preMergeEpoch = Int(group.epoch())

            // 4. Validate group_info.
            guard let groupInfo = commitBundle.groupInfo, !groupInfo.isEmpty else {
                try mlsClient.clearPendingCommit(in: cid)
                log.error("[E2E] commitEviction failed: group_info is required for \(cidString)", subsystems: .mls)
                return
            }

            // 5. Send eviction commit to server.
            let body = CommitEvictionRequestBody(
                targetUserIds: targetUserIds,
                commit: commitBundle.commit,
                groupInfo: groupInfo,
                epoch: preMergeEpoch
            )

            log.debug("[E2E] Sending commit eviction for \(targetUserIds.count) ghost member(s) in \(cidString), epoch: \(preMergeEpoch)", subsystems: .mls)

            apiClient.request(endpoint: .commitEviction(cid: cid, body: body)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // 6. Server OK → merge commit, clear pending ghost queue, persist.
                    do {
                        try self.mergePendingCommit(in: cid)
                        self.deletePendingRemoveMembers(userIds: targetUserIds, channelCid: cidString)
                        log.debug("[E2E] Commit eviction succeeded for \(cidString), removed \(targetUserIds.count) ghost member(s)", subsystems: .mls)
                    } catch {
                        log.error("[E2E] Failed to merge pending commit after eviction: \(error)", subsystems: .mls)
                    }
                case .failure(let error):
                    // 7. Fail → rollback, persist cleanup.
                    do {
                        try self.clearPendingCommit(in: cid)
                    } catch {
                        log.error("[E2E] Failed to clear pending commit after eviction failure: \(error)", subsystems: .mls)
                    }
                    log.error("[E2E] Commit eviction failed for \(cidString): \(error)", subsystems: .mls)
                }
            }
        } catch {
            log.error("[E2E] Failed to create eviction commit for \(cidString): \(error)", subsystems: .mls)
        }
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
    
    /// Joins a channel's MLS group from its server-published `group_info` via an external
    /// commit. Used when there is no usable Welcome (multi-device, invite-accept, or a
    /// Welcome that failed with `NoMatchingKeyPackage`).
    ///
    /// - Parameter retriesRemaining: When the server returns `group_info` flagged
    ///   `is_stale` (an active member hasn't published a fresh `group_info` for the current
    ///   epoch yet), we cannot external-join against it. We retry with backoff up to this
    ///   many times — the join succeeds once a member uploads fresh `group_info` (e.g. on
    ///   their next commit). This is the client half; the backend must actually refresh
    ///   `group_info` after epoch changes for the retries to converge.
    func externalJoinChannel(cid: ChannelId, retriesRemaining: Int = 3, completion: @escaping (Error?) -> Void) {
        // A realtime/sync Welcome may already have created the group — nothing to do.
        if mlsClient.isGroupLoaded(cid: cid.rawValue) {
            completion(nil)
            return
        }
        apiClient.request(endpoint: .getGroupInfo(cid: cid)) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let groupInfo):
                guard !groupInfo.isStale else {
                    guard retriesRemaining > 0 else {
                        log.error("[E2E] group_info still stale for \(cid) after retries; an active member must publish a fresh group_info", subsystems: .mls)
                        completion(ClientError("Group info is stale; no fresh group_info available yet."))
                        return
                    }
                    let delaySeconds = TimeInterval(3 * (4 - retriesRemaining)) // 3s, 6s, 9s
                    log.debug("[E2E] group_info stale for \(cid); retrying external join in \(delaySeconds)s (\(retriesRemaining) left)", subsystems: .mls)
                    DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                        self?.externalJoinChannel(cid: cid, retriesRemaining: retriesRemaining - 1, completion: completion)
                    }
                    return
                }
                // A Welcome may have created the group while we were fetching group_info —
                // don't external-join over it (that would fork the group at a new epoch).
                guard !mlsClient.isGroupLoaded(cid: cid.rawValue) else {
                    completion(nil)
                    return
                }
                do {
                    let externalJoinResult = try mlsClient.externalJoin(groupInfo: groupInfo.groupInfo.data)
                    log.debug("External join group with cid: \(cid) info: \(externalJoinResult.group.epoch())", subsystems: .mls)
                    requestExternalJoin(to: cid, externalJoinResult: externalJoinResult, completion: completion)
                } catch (let error) {
                    log.error("[E2E] External join failed to process group_info for \(cid): \(error)", subsystems: .mls)
                    completion(error)
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
    
    /// Resolves the channel id whose MLS group should be used for crypto operations in `cid`.
    ///
    /// Topics share their parent channel's MLS group, so a topic resolves to its parent cid;
    /// every other channel resolves to itself. If the topic's parent can't be resolved (e.g.
    /// its row isn't in the DB yet) the topic cid is returned unchanged — the caller then
    /// fails to load a group and the message is buffered for retry, same as any missing group.
    func mlsGroupCid(for cid: ChannelId) -> ChannelId {
        guard cid.type == .topic else { return cid }
        var resolved = cid
        database.viewContext.performAndWait {
            guard let dto = ChannelDTO.load(cid: cid, context: database.viewContext),
                  let parentCid = try? ChannelId(cid: dto.mlsGroupCid) else { return }
            resolved = parentCid
        }
        return resolved
    }

    func encryptedMessage(_ message: E2ePayload, in cid: ChannelId) throws -> ([UInt8], Int) {
        // Resolve the group cid and encode the payload up front (no MLS state touched),
        // then perform the actual MLS encryption on the shared serial queue so it never
        // runs concurrently with a decrypt/commit on the same group (correctness) and
        // never contends with them on the MLS SQLite store (latency). The operation does
        // no Core Data work, so blocking the caller via `waitUntilFinished` is deadlock-safe.
        let groupCid = mlsGroupCid(for: cid).rawValue
        let data = try JSONEncoder().encode(message)
        var result: Result<([UInt8], Int), Error>?
        let op = BlockOperation { [weak self] in
            guard let self else {
                result = .failure(ClientError.MlsNoProviderError())
                return
            }
            do {
                let group = try self.mlsClient.loadGroup(with: groupCid)
                let encryptedData = try self.mlsClient.encrypt(inputData: data, in: group)
                result = .success((encryptedData.uint8Array, Int(group.epoch())))
            } catch {
                result = .failure(error)
            }
        }
        // Sends run ahead of background sync so they aren't blocked by a sync backlog.
        op.queuePriority = .high
        decryptQueue.addOperations([op], waitUntilFinished: true)
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw ClientError.Unexpected("Encryption did not complete.")
        }
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
        // Advance (do NOT clear) the cursor so a later re-add/re-invite won't replay the
        // old Welcome (already-consumed KeyPackage → NoMatchingKeyPackage). See
        // `advanceE2eSyncCursor`.
        advanceE2eSyncCursor(for: cid)
    }

    public func deleteGroups(cids: [String]) throws {
        for cid in cids {
            if mlsClient.isGroupLoaded(cid: cid) {
                try mlsClient.deleteGroup(cid: cid)
            }
            advanceE2eSyncCursor(for: cid)
        }
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
        // Foreground/realtime decrypts run ahead of background sync work so a freshly
        // arrived message is not stuck showing the "encrypted" placeholder behind a
        // large sync backlog.
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            self.decryptMessagePayloadSync(
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                completion: completion
            )
        }
        op.queuePriority = .high
        decryptQueue.addOperation(op)
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
