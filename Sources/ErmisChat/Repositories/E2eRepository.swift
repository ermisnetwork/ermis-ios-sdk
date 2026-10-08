//
// Copyright 2025 Ermis Inc.
//

import Foundation
import open_mls_ios
import CoreData
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

private enum E2eeSyncApplyError: LocalizedError {
    case missingAccount
    case missingCiphertext(messageId: String)
    case missingMember
    case missingProtocolPayload(type: MLSProtocolType)
    case epochMismatch(local: UInt64, event: Int)
    case invalidCommit(reason: String)
    case unsupportedEvent(type: String)

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return "The E2EE sync event has no active account."
        case .missingCiphertext(let messageId):
            return "Application message \(messageId) has no MLS ciphertext."
        case .missingMember:
            return "Member removal event has no member payload."
        case .missingProtocolPayload(let type):
            return "MLS protocol event \(type.rawValue) is missing required bytes."
        case .epochMismatch(let local, let event):
            return "MLS epoch mismatch: local=\(local), event=\(event)."
        case .invalidCommit(let reason):
            return "Invalid MLS commit event: \(reason)."
        case .unsupportedEvent(let type):
            return "Unsupported E2EE sync event: \(type)."
        }
    }

    var repairCategory: String {
        switch self {
        case .missingAccount: return "missing_account"
        case .missingCiphertext: return "missing_ciphertext"
        case .missingMember: return "missing_member"
        case .missingProtocolPayload: return "missing_protocol_payload"
        case .epochMismatch: return "epoch_mismatch"
        case .invalidCommit: return "invalid_commit"
        case .unsupportedEvent: return "unsupported_event"
        }
    }
}

enum E2eeMessageEpochRecoveryError: LocalizedError {
    case ownerReleased
    case invalidRejection
    case scopeStillBehind(local: UInt64, required: Int64)
    case scopeNotReady(cid: String)

    var errorDescription: String? {
        switch self {
        case .ownerReleased:
            return "The E2EE repository was released during epoch recovery."
        case .invalidRejection:
            return "The epoch-stale rejection cannot safely rebind this message intent."
        case .scopeStillBehind(let local, let required):
            return "E2EE scope sync finished below the required epoch (local=\(local), required=\(required))."
        case .scopeNotReady(let cid):
            return "The E2EE scope is not safe for message re-encryption: \(cid)."
        }
    }
}

private struct E2eeMlsRebootstrapCheckpoint: Codable, Equatable {
    let cid: String
    let providerPath: String
    let completeBody: CompleteMlsRebootstrapRequestBody
}

struct E2eeMlsRebootstrapClaimIntent: Codable, Equatable {
    let cid: String
    let operationKey: String
    let expectedGeneration: Int
    let expectedEpoch: Int
    let protocolVersion: Int

    func matches(cid: String, state: MlsGenerationStatePayload) -> Bool {
        self.cid == cid
            && expectedGeneration == state.groupGeneration
            && expectedEpoch == state.currentEpoch
            && protocolVersion == MlsRebootstrapCapabilityPayload.currentProtocolVersion
    }
}

/// A health-check/pong proves only that the socket is alive. It must never trigger a full
/// history sync because pongs arrive periodically while the connection is healthy. Catch-up is
/// tied to the public transition into `connected`, which is emitted once per connect/reconnect.
enum E2eeFullSyncTriggerPolicy {
    static func shouldRunFullSync(for event: any Event) -> Bool {
        guard let connection = event as? ConnectionStatusUpdated else { return false }
        return connection.connectionStatus == .connected
    }
}

/// Classifies a durable commit against the OpenMLS provider epoch without mutating either store.
///
/// A lower target epoch is historical: the provider has already advanced beyond it, so replaying
/// the commit is impossible and blocking the scope would deadlock migration/recovery forever. A
/// higher non-adjacent target is a real gap and remains scope-blocking.
enum E2eeCommitEpochAction: Equatable {
    case supersedeHistorical
    case finalizeActive
    case processNext
    case blockGap

    static func resolve(localEpoch: UInt64, targetEpoch: UInt64) -> Self {
        if targetEpoch < localEpoch {
            return .supersedeHistorical
        }
        if targetEpoch == localEpoch {
            return .finalizeActive
        }
        let next = localEpoch.addingReportingOverflow(1)
        if !next.overflow, targetEpoch == next.partialValue {
            return .processNext
        }
        return .blockGap
    }
}

/// Thread-safe admission and sequencing for missing-group bootstrap. A scope remains admitted
/// until its active bootstrap completes, so concurrent lifecycle callbacks cannot start a second
/// external join for the same channel.
final class E2eeBootstrapQueue {
    private let lock = NSLock()
    private var pending: [ChannelId] = []
    private var admitted: Set<String> = []
    private var deferredSync: Set<String> = []
    private var isRunning = false

    func enqueue(_ cid: ChannelId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard admitted.insert(cid.rawValue).inserted else { return false }
        pending.append(cid)
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func dequeue() -> ChannelId? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            isRunning = false
            return nil
        }
        return pending.removeFirst()
    }

    func finish(_ cid: ChannelId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        admitted.remove(cid.rawValue)
        return deferredSync.remove(cid.rawValue) != nil
    }

    func deferSyncIfAdmitted(_ cid: ChannelId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard admitted.contains(cid.rawValue) else { return false }
        deferredSync.insert(cid.rawValue)
        return true
    }

    func reset() {
        lock.lock()
        pending.removeAll()
        admitted.removeAll()
        deferredSync.removeAll()
        isRunning = false
        lock.unlock()
    }
}

enum E2eePartialWelcomeFallbackEligibility: Equatable {
    case missingTypedPrerequisite
    case disabled
    case eligible

    static func resolve(hasTypedPrerequisite: Bool, controlEnabled: Bool) -> Self {
        guard hasTypedPrerequisite else { return .missingTypedPrerequisite }
        return controlEnabled ? .eligible : .disabled
    }
}

enum E2eeApplicationEpochAction: Equatable {
    case preJoinHistorical
    case pendingGroup
    case decrypt

    static func resolve(
        envelope: E2eSyncEventEnvelope,
        messageEpoch: Int64?,
        firstDecryptableEpoch: Int64?,
        joinBoundary: E2eSyncEventEnvelope?,
        awaitingExternalCommitBoundary: Bool,
        hasGroup: Bool
    ) -> Self {
        if let joinBoundary,
           E2eSyncEventEnvelope.canonicalScopeSyncOrder(envelope, joinBoundary) {
            return .preJoinHistorical
        }
        if let messageEpoch, let firstDecryptableEpoch,
           messageEpoch < firstDecryptableEpoch {
            return .preJoinHistorical
        }
        // A merged external-join receipt makes the local group crypto-safe, but it does not
        // identify which same-epoch application events are before the external commit yet.
        // Keep them durable until that exact boundary is applied.
        if awaitingExternalCommitBoundary { return .pendingGroup }
        return hasGroup ? .decrypt : .pendingGroup
    }

    // Kept for focused classifier tests and callers that do not have a durable envelope yet.
    static func resolve(
        messageEpoch: Int64?,
        firstDecryptableEpoch: Int64?,
        hasGroup: Bool
    ) -> Self {
        if let messageEpoch, let firstDecryptableEpoch, messageEpoch < firstDecryptableEpoch {
            return .preJoinHistorical
        }
        return hasGroup ? .decrypt : .pendingGroup
    }
}

/// Classifies the only safe application-message replay shortcut after a process interruption.
///
/// OpenMLS may report `MessageAlreadyConsumed` when the receiver ratchet was saved before the
/// durable apply cursor advanced. The event can be finalized from the local plaintext cache only
/// when that cache proves it came from the exact same ciphertext. Every other error (including a
/// bad tag/malformed TLS message) and a missing/mismatched proof must follow the repair path.
enum E2eeApplicationReplayRecovery {
    static func canFinalizeFromCachedPlaintext(
        error: Error,
        cachedCiphertextHash: Data?,
        ciphertext: Data
    ) -> Bool {
        guard let mlsError = error as? MlsError,
              case .MessageAlreadyConsumed = mlsError,
              let cachedCiphertextHash else {
            return false
        }
        return cachedCiphertextHash == Data(SHA256.hash(data: ciphertext))
    }
}

private enum E2eeSyncApplyDisposition {
    /// The event body is complete, but the caller must atomically advance its durable apply cursor.
    case requiresCursorAdvance
    /// The event and exact apply cursor were already finalized in one durable-store transaction.
    case cursorAdvancedAtomically
    /// The external commit is already in the local provider. Persist cursor, boundary and receipt
    /// finalization together instead of reopening the old cursor/receipt crash window.
    case finalizeExternalJoin(
        commitHash: Data,
        epoch: UInt64,
        deviceId: String,
        requireReceipt: Bool
    )
    /// Application classification and cursor movement must be committed together.
    case application(E2eeApplicationDisposition)
}

/// Observable lifecycle state for one channel's effective MLS group.
public enum E2eeChannelReadiness: String, Equatable, Sendable {
    case restoring
    case syncing
    case joining
    case waitingForRepair = "waiting_for_repair"
    case rebootstrapping
    case recovered
    case historyIncomplete = "history_incomplete"
    case clientUpgradeRequired = "client_upgrade_required"
    case infrastructureRetryable = "infrastructure_retryable"
    case ready
    case needsRetry
    case failed
}

enum E2eeMlsRebootstrapFailureClassifier {
    static func readiness(for error: Error) -> E2eeChannelReadiness {
        let apiError: ErmisApiError?
        if let direct = error as? ErmisApiError {
            apiError = direct
        } else if let clientError = error as? ClientError {
            apiError = clientError.underlyingError as? ErmisApiError
        } else {
            apiError = nil
        }
        guard let apiError else { return .infrastructureRetryable }
        if [404, 405, 501].contains(apiError.httpStatusCode) {
            return .clientUpgradeRequired
        }
        switch apiError.mlsRebootstrapState {
        case .upgradeRequired?, .incompatibleServerClient?:
            return .clientUpgradeRequired
        case .repairing?, .eligible?, .cancelledRepairWon?:
            return .waitingForRepair
        case .preparing?:
            return .rebootstrapping
        default:
            return .infrastructureRetryable
        }
    }
}

/// Validates the server-owned KeyPackage refill contract shared by native clients.
/// Bellboy bounds the configured target to 100, and only a durable demand generation
/// authorizes client-side generation of new private KeyPackage material.
enum E2eeKeyPackageRefillPolicy {
    static let maximumTarget = 100
    static let maximumAttempts = 5
    static let retryBaseDelay: TimeInterval = 0.25
    static let cooldown: TimeInterval = 60

    static func batchSize(
        remaining: Int,
        target: Int,
        lowWatermark: Int,
        requestedDelta: Int,
        refillGeneration: Int?
    ) -> Int? {
        guard remaining >= 0,
              (1...maximumTarget).contains(target),
              lowWatermark >= 0,
              lowWatermark < target,
              requestedDelta == max(target - remaining, 0)
        else {
            return nil
        }
        guard let refillGeneration, refillGeneration > 0 else {
            return requestedDelta == 0 || remaining > lowWatermark ? 0 : nil
        }
        guard requestedDelta > 0,
              requestedDelta <= target
        else {
            return requestedDelta == 0 ? 0 : nil
        }
        return requestedDelta
    }

    static func shouldReconcileHealthCheck(
        remaining: Int,
        target: Int,
        lowWatermark: Int
    ) -> Bool {
        remaining >= 0
            && (1...maximumTarget).contains(target)
            && lowWatermark >= 0
            && lowWatermark < target
            && remaining <= lowWatermark
    }

    static func isValidEvent(
        usableCount: Int,
        target: Int,
        requestedDelta: Int,
        generation: Int
    ) -> Bool {
        usableCount >= 0
            && (1...maximumTarget).contains(target)
            && usableCount <= target
            && requestedDelta == target - usableCount
            && requestedDelta > 0
            && generation > 0
    }
}

class E2eRepository: EventsControllerDelegate {
    let database: DatabaseContainer
    let eventNotificationCenter: EventNotificationCenter
    let mlsClient: MlsClient
    let apiClient: APIClient
    var mlsRolloutControls = E2eeMlsRolloutControls()

    private lazy var e2eeAttachmentReceiveCoordinator = E2eeAttachmentReceiveCoordinator(
        apiClient: apiClient,
        database: database
    )

    private lazy var groupInfoRepairCoordinator = GroupInfoRepairCoordinator(
        store: UserDefaultsGroupInfoRepairStore(defaults: mlsClient.userDefaults)
    ) { cid, status, retryDelay in
        var userInfo: [String: Any] = ["cid": cid, "status": status.rawValue]
        if let retryDelay { userInfo["retry_after_seconds"] = retryDelay }
        NotificationCenter.default.post(
            name: .ermisGroupInfoRepairStateChanged,
            object: nil,
            userInfo: userInfo
        )
    }
    
    let eventController: EventsController
    
    private let keyPackageRefillStateQueue = DispatchQueue(
        label: "io.ermis.e2e.key-package-refill-state"
    )
    private var keyPackageRefillInFlight = false
    private var keyPackageRefillCompletedAtUptime: TimeInterval = 0
    
    private static let loginTimeKey = "ermis_mls_login_time"
    
    /// The timestamp when the current user session started on this device.
    /// Stored in UserDefaults so it survives app restarts but is device-local.
    var loginTime: Date? {
        get { mlsClient.userDefaults.object(forKey: Self.loginTimeKey) as? Date }
        set { mlsClient.userDefaults.set(newValue, forKey: Self.loginTimeKey) }
    }
    
    /// Returns the saved composite sync cursor (`{created_at, event_id}`) for a channel/scope,
    /// or nil if none is stored. Scoped by the current userId so cursors from different users
    /// don't interfere. A legacy millisecond cursor (from before the scope_sync migration) is
    /// transparently upgraded to a composite cursor with the all-zero event id.
    private func e2eSyncCursor(for channelId: String) -> ScopeSyncCursorPayload? {
        guard let userId = mlsClient.userId else { return nil }
        guard let userCursors = mlsClient.userDefaults.dictionary(forKey: MlsClient.cursorKey)?[userId] as? [String: Any],
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
        var all = mlsClient.userDefaults.dictionary(forKey: MlsClient.cursorKey) ?? [:]
        var userCursors = all[userId] as? [String: Any] ?? [:]
        for (cid, cursor) in cursors {
            userCursors[cid] = ["created_at": cursor.createdAt, "event_id": cursor.eventId]
        }
        all[userId] = userCursors
        mlsClient.userDefaults.set(all, forKey: MlsClient.cursorKey)
    }

    /// Removes the sync cursor for a given channel ID from UserDefaults.
    /// Called when an MLS group is deleted so the stale cursor doesn't persist.
    private func removeE2eSyncCursor(for channelId: String) {
        guard let userId = mlsClient.userId else { return }
        var all = mlsClient.userDefaults.dictionary(forKey: MlsClient.cursorKey) ?? [:]
        var userCursors = all[userId] as? [String: Any] ?? [:]
        userCursors.removeValue(forKey: channelId)
        all[userId] = userCursors
        mlsClient.userDefaults.set(all, forKey: MlsClient.cursorKey)
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
        do {
            if let durableCursor = try durableInboxStore.removedCursor(accountId: userId) {
                return durableCursor
            }
        } catch {
            log.error(
                "[E2eSync] state=removed_cursor_read_failed \(PrivacySafeLogMetadata.errorFields(error))",
                subsystems: .mls
            )
            return nil
        }

        // Migration-only fallback. Once the Core Data cursor exists it is authoritative.
        let all = mlsClient.userDefaults.dictionary(forKey: Self.removedCursorKey) as? [String: [String: String]]
        guard let dict = all?[userId],
              let removedAt = dict["removed_at"],
              let eventId = dict["event_id"] else { return nil }
        return RemovedSyncCursorPayload(removedAt: removedAt, eventId: eventId)
    }

    /// Persists the `removed_channels` cursor for the current user. Stored as RFC3339
    /// strings so sub-millisecond precision in `removed_at` is preserved.
    private func saveRemovedSyncCursor(_ cursor: RemovedSyncCursorPayload) {
        guard let userId = mlsClient.userId else { return }
        var all = mlsClient.userDefaults.dictionary(forKey: Self.removedCursorKey) as? [String: [String: String]] ?? [:]
        all[userId] = ["removed_at": cursor.removedAt, "event_id": cursor.eventId]
        mlsClient.userDefaults.set(all, forKey: Self.removedCursorKey)
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

    /// Serializes every OpenMLS group mutation in the main app process. This includes decrypt,
    /// sync protocol events, outgoing encryption, membership commits, external join and deletion.
    private let mutationExecutor = MlsMutationExecutor()
    
    /// Guards against multiple concurrent syncPage tasks.
    /// Only one sync (from either `performE2eSync` or `performE2eChannelSync`) can run at a time.
    private let syncLock = NSLock()
    private var isSyncing = false
    private var activeSyncCids: Set<String> = []
    private var activeSyncCompletions: [() -> Void] = []
    private let retainedReplayLock = NSLock()
    private var retainedReplayBlockedCids: Set<String> = []
    private var pendingInitialSyncCursorBatches: [[String: ScopeSyncCursorPayload]] = []

    /// Per-channel sync requests that arrived while another sync was already running. Instead of
    /// dropping them (which left a freshly accepted/received channel un-synced until the next
    /// channel-list save), they are drained in `finishSync` as soon as the current sync ends.
    /// Guarded by `syncLock`.
    private var pendingChannelSyncCids: Set<String> = []
    private var pendingSyncCompletions: [() -> Void] = []

    /// Throttle for the full multi-channel sync. A connection transition is the normal trigger;
    /// the throttle still coalesces duplicate lifecycle/connect notifications defensively.
    private let syncThrottleInterval: TimeInterval = 2.0
    private let syncThrottleQueue = DispatchQueue(label: "io.ermis.e2e.sync-throttle")
    private var lastSyncTriggeredAt: Date?
    private var pendingSyncWorkItem: DispatchWorkItem?

    private lazy var durableInboxStore = E2eeDurableInboxStore(database: database)
    private let durableApplyLock = NSLock()
    private var blockedDurableScopes: Set<String> = []
    private var enqueuedDurableEvents: Set<String> = []
    private var scheduledDurableDrains: Set<String> = []

    private let readinessLock = NSLock()
    private var readinessByCid: [String: E2eeChannelReadiness] = [:]
    private var readinessCallbacks: [String: [(E2eeChannelReadiness) -> Void]] = [:]

    /// Missing-group bootstraps are serialized because every external commit mutates the same
    /// OpenMLS provider and publishes a new group epoch/GroupInfo.
    private let bootstrapQueue = E2eeBootstrapQueue()

    private var membershipRefresh: E2eeMembershipRefreshCoordinator?

    /// Also used by local accept when realtime delivery is missing or arrives later.
    func reconcileAcceptedMembership(in cid: ChannelId) {
        membershipRefresh?.refresh(mlsGroupCid(for: cid), recheckIfInFlight: true)
    }

    /// Dedicated private-queue context for E2EE decrypt reads (decrypt cache + pending-message
    /// lookups). Kept separate from `backgroundReadOnlyContext` — which the synchronous
    /// send/encrypt path blocks via `waitUntilFinished` — so a decrypt running on the mutation executor
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
        mlsClient.installMutationExecutorAssertion { [weak mutationExecutor] in
            mutationExecutor?.assertIsExecuting()
        }
        membershipRefresh = E2eeMembershipRefreshCoordinator(
            database: database,
            currentSession: { [weak self] in
                guard let self, let accountId = self.mlsClient.userId,
                      let deviceId = self.mlsClient.currentDeviceId else { return nil }
                return .init(accountId: accountId, deviceId: deviceId)
            },
            fetch: { [weak self] cid, completion in
                self?.apiClient.request(
                    endpoint: .updateChannel(query: .init(cid: cid, pageSize: 0, membersLimit: 0, watchersLimit: 0)),
                    completion: completion
                )
            },
            publish: { [weak self] event, completion in
                self?.eventNotificationCenter.process(event, completion: completion)
            },
            finished: { [weak self] cid, result in
                guard let self else { return }
                switch result {
                case .success: self.enqueueBootstrap(for: cid)
                case .failure: self.setReadiness(.needsRetry, for: cid.rawValue)
                }
            }
        )
        eventController.delegate = self
    }

    private lazy var mlsRolloutTelemetryBuffer = E2eeMlsRolloutTelemetryBuffer { [weak self] observations, completion in
        guard let self else {
            completion()
            return
        }
        self.apiClient.request(endpoint: .reportMlsRolloutTelemetry(observations: observations)) { result in
            if case .failure = result {
                log.error("[MLS] state=rollout_telemetry_failed reason=transport_error", subsystems: .mls)
            }
            completion()
        }
    }

    private func emitMlsRolloutMetric(_ observation: E2eeMlsRolloutMetricObservation) {
        mlsRolloutControls.metricObserver?(observation)
        guard mlsRolloutControls.clientTelemetryEnabled else { return }
        if mlsRolloutTelemetryBuffer.record(observation) == .droppedQueueFull {
            log.error("[MLS] state=rollout_telemetry_failed reason=queue_full", subsystems: .mls)
        }
    }
    
    func eventsController(_ controller: EventsController, didReceiveEvent event: any Event) {
        if membershipRefresh?.handleMemberEvent(event, cachedMlsEnabled: { [weak self] cid in
            guard let self else { return false }
            var enabled = false
            self.database.viewContext.performAndWait {
                enabled = ChannelDTO.load(cid: cid, context: self.database.viewContext)?.mlsEnabled == true
            }
            return enabled
        }) == true { return }
        if E2eeFullSyncTriggerPolicy.shouldRunFullSync(for: event) {
            performE2eSync(trigger: "connection_established")
            reconcileKeyPackageInventory(reason: "manual")
        } else if let event = event as? HealthCheckEvent {
            handleHealthCheckEvent(event)
        } else if event is KeyPackageRefillEvent {
            reconcileKeyPackageInventory(reason: "manual")
        } else if let event = event as? MessageNewEvent {
            decryptNewMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? NotificationMessageNewEvent {
            decryptNewMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? MessageUpdatedEvent {
            decryptUpdatedMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? MLSEvent {
            handleMlsEvent(event)
        } else if let event = event as? GroupInfoRefreshRequestedEvent {
            handleGroupInfoRefreshRequested(event)
        } else if let event = event as? GroupInfoUploadedEvent {
            handleGroupInfoUploaded(event)
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
        let trace = E2eeJoinTrace.Context(cid: event.cid.rawValue)
        trace.info(
            stage: "invite_accepted",
            source: "websocket",
            receipt: joinReceiptTraceStatus(for: event.cid.rawValue),
            groupLoaded: mlsClient.isGroupLoaded(cid: event.cid.rawValue)
        )
        // Use the same pre-sync -> typed fallback -> post-sync coordinator as
        // startup. This also retries a durable prerequisite recorded while the
        // invitation was still pending; no timer or generic-error fallback.
        if event.member.userId == mlsClient.userId {
            reconcileAcceptedMembership(in: event.cid)
        } else {
            enqueueBootstrap(for: event.cid)
        }
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
            membershipRefresh?.invalidate(event.cid)
            if let scope = groupInfoRepairScope {
                groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cidString)
            }
            let trace = E2eeJoinTrace.Context(cid: cidString)
            let groupLoaded = mlsClient.isGroupLoaded(cid: cidString)
            trace.info(
                stage: "current_user_removed",
                source: "websocket",
                receipt: joinReceiptTraceStatus(for: cidString),
                groupLoaded: groupLoaded
            )
            guard groupLoaded else {
                trace.info(
                    stage: "local_group_delete_finished",
                    source: "websocket",
                    result: "already_missing",
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: false
                )
                return
            }
            do {
                log.debug("[MLS] state=current_user_removed action=delete_group", subsystems: .mls)
                try deleteGroup(cid: cidString)
                try deleteGroups(cids: event.topicCids.map { $0.rawValue })
                trace.info(
                    stage: "local_group_delete_finished",
                    source: "websocket",
                    result: "deleted",
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: mlsClient.isGroupLoaded(cid: cidString)
                )
            } catch {
                trace.failure(
                    stage: "local_group_delete_failed",
                    source: "websocket",
                    error: error,
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: mlsClient.isGroupLoaded(cid: cidString)
                )
                log.error(
                    "[MLS] state=group_delete_failed reason=current_user_removed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
            }
            return
        }

        // Admin kick already has an MLS commit in the standard remove flow → no extra cleanup.
        guard event.isSelfLeave else { return }

        // Another user self-left → queue ghost cleanup.
        database.write { session in
            session.savePendingRemoveMember(userId: targetUserId, channelCid: cidString)
        }
        log.debug("[E2E] state=pending_eviction_saved reason=member_self_left", subsystems: .mls)

        // Designated evictor performs actual MLS removal.
        if isDesignatedEvictor(cid: event.cid) {
            commitEviction(cid: event.cid, targetUserIds: [targetUserId])
        }
    }
    
    private func handleMlsEvent(_ mlsEvent: MLSEvent) {
        let mlsProtocol = mlsEvent.mlsProtocol
        let cid = mlsEvent.cid.rawValue
        let trace = E2eeJoinTrace.Context(cid: cid)
        let targetedAtCurrentUser = mlsProtocol.targetUserIds.map { targetUserIds in
            mlsClient.userId.map(targetUserIds.contains) ?? false
        }
        trace.info(
            stage: "protocol_received",
            source: "websocket",
            protocolType: mlsProtocol.type.rawValue,
            receipt: joinReceiptTraceStatus(for: cid),
            groupLoaded: mlsClient.isGroupLoaded(cid: cid),
            targetedAtCurrentUser: targetedAtCurrentUser,
            eventEpoch: mlsProtocol.epoch
        )
        if let deviceId = mlsProtocol.deviceId, let currentDeviceId = mlsClient.currentDeviceId, deviceId == currentDeviceId {
            trace.info(
                stage: "protocol_ignored",
                source: "websocket",
                protocolType: mlsProtocol.type.rawValue,
                result: "ignored",
                reason: "current_device",
                groupLoaded: mlsClient.isGroupLoaded(cid: cid),
                eventEpoch: mlsProtocol.epoch
            )
            log.debug("[MLS] ignored event from self", subsystems: .mls)
            return
        }
        if mlsProtocol.type == .welcome,
           !mlsClient.isGroupLoaded(cid: cid),
           targetedAtCurrentUser == true,
           mlsProtocol.targetDeviceIds.map({ ids in
               mlsClient.currentDeviceId.map(ids.contains) ?? false
           }) != false {
            // Another device may accept while this device is no longer watching the
            // normal room. A targeted MLS notification still arrives. Refresh rights
            // and list metadata first; only durable replay may consume the Welcome or
            // record the typed prerequisite needed by external-join fallback.
            reconcileAcceptedMembership(in: mlsEvent.cid)
            return
        }
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            self.durableApplyLock.lock()
            let isBlocked = self.blockedDurableScopes.contains(cid)
            self.durableApplyLock.unlock()
            guard !isBlocked else {
                trace.info(
                    stage: "protocol_deferred",
                    source: "websocket",
                    protocolType: mlsProtocol.type.rawValue,
                    result: "scope_sync_requested",
                    reason: "durable_repair",
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                    eventEpoch: mlsProtocol.epoch
                )
                log.error("[MLS] state=realtime_protocol_blocked reason=durable_repair", subsystems: .mls)
                self.performE2eChannelSync(cid: mlsEvent.cid)
                return
            }
            do {
                switch mlsEvent.mlsProtocol.type {
                case .commit, .externalCommit:
                    // Commits need a durable raw envelope and exact ciphertext/epoch proof before
                    // OpenMLS advances the group. Realtime delivery only triggers scope sync.
                    trace.info(
                        stage: "protocol_deferred",
                        source: "websocket",
                        protocolType: mlsProtocol.type.rawValue,
                        result: "scope_sync_requested",
                        reason: "durable_apply_required",
                        receipt: self.joinReceiptTraceStatus(for: cid),
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                        eventEpoch: mlsProtocol.epoch
                    )
                    self.performE2eChannelSync(cid: mlsEvent.cid)
                case .welcome:
                    if mlsProtocol.groupGeneration > 0 {
                        // Generation activation is installed only from the durable scope-sync
                        // envelope, after the exact event has been persisted. Realtime is only
                        // a wake-up signal for that ordered path.
                        self.performE2eChannelSync(cid: mlsEvent.cid)
                        return
                    }
                    //                    break
                    guard !self.shouldSkipWelcome(
                        cid: cid,
                        incomingGeneration: mlsProtocol.groupGeneration
                    ) else {
                        trace.info(
                            stage: "welcome_skipped",
                            source: "websocket",
                            protocolType: mlsProtocol.type.rawValue,
                            result: "skipped",
                            reason: "group_exists",
                            receipt: self.joinReceiptTraceStatus(for: cid),
                            groupLoaded: true,
                            eventEpoch: mlsProtocol.epoch
                        )
                        log.debug("[MLS] state=welcome_skipped reason=group_exists", subsystems: .mls)
                        return
                    }
                    if let targetUserIds = mlsProtocol.targetUserIds,
                       let currentUserId = mlsClient.userId,
                       !targetUserIds.contains(currentUserId) {
                        trace.info(
                            stage: "welcome_skipped",
                            source: "websocket",
                            protocolType: mlsProtocol.type.rawValue,
                            result: "skipped",
                            reason: "not_targeted",
                            groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                            targetedAtCurrentUser: false,
                            eventEpoch: mlsProtocol.epoch
                        )
                        log.debug("[E2eSync] Skipping welcome not targeted at current user", subsystems: .mls)
                        return
                    }
                    if let targetDeviceIds = mlsProtocol.targetDeviceIds,
                       let currentDeviceId = mlsClient.currentDeviceId,
                       !targetDeviceIds.contains(currentDeviceId) {
                        return
                    }
                    guard let welcome = mlsProtocol.welcome,
                          let ratchetTreeData = mlsProtocol.ratchetTree?.data,
                          let ratchetTree = try? RatchetTree.fromBytes(data: ratchetTreeData) else {
                        trace.info(
                            stage: "welcome_rejected",
                            source: "websocket",
                            protocolType: mlsProtocol.type.rawValue,
                            result: "rejected",
                            reason: "payload_invalid",
                            groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                            eventEpoch: mlsProtocol.epoch
                        )
                        return
                    }
                    trace.info(
                        stage: "welcome_processing",
                        source: "websocket",
                        protocolType: mlsProtocol.type.rawValue,
                        receipt: self.joinReceiptTraceStatus(for: cid),
                        groupLoaded: false,
                        targetedAtCurrentUser: targetedAtCurrentUser,
                        eventEpoch: mlsProtocol.epoch
                    )
                    try self.mlsClient.joinWithWelcome(
                        cid: mlsEvent.cid.rawValue,
                        welcome: welcome.data,
                        ratchetTree: ratchetTree,
                        generation: UInt64(mlsProtocol.groupGeneration),
                        groupId: mlsProtocol.groupId.map { Data($0) }
                    )
                    let joinedEpoch = try? self.mlsClient.loadGroup(with: cid).epoch()
                    trace.info(
                        stage: "welcome_joined",
                        source: "websocket",
                        protocolType: mlsProtocol.type.rawValue,
                        result: "joined",
                        receipt: self.joinReceiptTraceStatus(for: cid),
                        groupLoaded: true,
                        eventEpoch: mlsProtocol.epoch,
                        localEpoch: joinedEpoch
                    )
                    self.saveMlsGroupJoinedAt(cidString: mlsEvent.cid.rawValue) { [weak self] error in
                        guard let self else { return }
                        if let error {
                            trace.failure(
                                stage: "welcome_anchor_persist_failed",
                                source: "websocket",
                                error: error,
                                protocolType: mlsProtocol.type.rawValue,
                                receipt: self.joinReceiptTraceStatus(for: cid),
                                groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                                eventEpoch: mlsProtocol.epoch,
                                localEpoch: joinedEpoch
                            )
                            return
                        }
                        trace.info(
                            stage: "welcome_anchor_persisted",
                            source: "websocket",
                            protocolType: mlsProtocol.type.rawValue,
                            result: "persisted",
                            receipt: self.joinReceiptTraceStatus(for: cid),
                            groupLoaded: true,
                            eventEpoch: mlsProtocol.epoch,
                            localEpoch: joinedEpoch
                        )
                        self.normalizeHistoricalApplications(cid: mlsEvent.cid)
                        self.reDecryptPendingMessages(in: mlsEvent.cid)
                    }
                case .proposal:
                    // Bellboy has no active standalone-proposal producer. Sync the durable event
                    // so the reserved wire value becomes an explicit repair issue, never an MLS
                    // mutation or silently advanced cursor.
                    trace.info(
                        stage: "protocol_deferred",
                        source: "websocket",
                        protocolType: mlsProtocol.type.rawValue,
                        result: "scope_sync_requested",
                        reason: "proposal_reserved",
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                        eventEpoch: mlsProtocol.epoch
                    )
                    self.performE2eChannelSync(cid: mlsEvent.cid)
                }
            } catch {
                trace.failure(
                    stage: "protocol_processing_failed",
                    source: "websocket",
                    error: error,
                    protocolType: mlsProtocol.type.rawValue,
                    receipt: self.joinReceiptTraceStatus(for: cid),
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                    eventEpoch: mlsProtocol.epoch
                )
                log.error(
                    "[MLS] state=realtime_event_process_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
                if mlsProtocol.type == .welcome, self.isMissingKeyPackageError(error) {
                    // Only the durable lane records the typed prerequisite and admits
                    // fallback. Realtime failures alone do not authorize external join.
                    self.performE2eChannelSync(cid: mlsEvent.cid)
                }
            }
        }
        // Realtime protocol messages unblock decryption — prioritise them over bulk sync.
        // Chained per channel so commits/welcomes advance the epoch in arrival order and never
        // overtake an in-flight sync op for the same group (see `enqueueGroupOperation`).
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: cid)
    }

    /// Enqueues a group-state mutation on the shared executor. The existing `Operation` wrapper
    /// is retained at call sites so cancellation and priority behavior stay source-compatible.
    @discardableResult
    private func enqueueGroupOperation(_ op: Operation, cidString: String) -> Operation {
        enqueueGroupOperation(op, cidStrings: [cidString])
    }

    /// Chains one operation behind every listed group and makes future work for each group wait
    /// for it. Removal pages use this barrier because one page may delete several MLS groups but
    /// its single user-scoped cursor cannot advance until every deletion is complete.
    @discardableResult
    private func enqueueGroupOperation(_ op: Operation, cidStrings: Set<String>) -> Operation {
        mutationExecutor.enqueue(scopeIds: cidStrings, priority: op.queuePriority) {
            guard !op.isCancelled else { return }
            op.start()
        }
    }

    private func performMlsMutation<T>(
        cidString: String,
        priority: Operation.QueuePriority = .normal,
        _ mutation: @escaping () throws -> T
    ) throws -> T {
        try mutationExecutor.sync(scopeIds: [cidString], priority: priority, work: mutation)
    }

    private func performMlsMutation<T>(
        cidStrings: Set<String>,
        priority: Operation.QueuePriority = .normal,
        _ mutation: @escaping () throws -> T
    ) throws -> T {
        try mutationExecutor.sync(scopeIds: cidStrings, priority: priority, work: mutation)
    }
    
    private func decryptNewMessageEventIfNeeded(message: ChatMessage, cid: ChannelId) {
        log.debug("[MLS] state=realtime_decrypt_started has_epoch=\(message.mlsEpoch != nil)")
        guard let encryptedData = message.encryptedData else { return }

        // The sender cannot decrypt its own current-device MLS ciphertext. Its plaintext was
        // durably cached before POST, so the WebSocket echo is only an acknowledgement/update.
        // Skipping only when that cache exists still allows messages from another device of the
        // same user to be decrypted normally.
        if Self.shouldSkipRealtimeDecrypt(
            isSentByCurrentUser: message.isSentByCurrentUser,
            hasCachedPlaintext: message.decryptedMessage != nil
        ) {
            log.debug(
                "[MLS] state=realtime_decrypt_skipped reason=own_echo_with_cache",
                subsystems: .mls
            )
            if let cached = message.decryptedMessage {
                e2eeAttachmentReceiveCoordinator.hydratePreviews(
                    payload: cached,
                    messageId: message.id,
                    cid: cid,
                    source: .websocket
                )
            }
            return
        }

        let groupCid = mlsGroupCid(for: cid)
        decryptMessagePayload(
            messageId: message.id,
            encryptedData: encryptedData,
            cid: cid,
            receiveSource: .websocket
        ) { [weak self] result in
            guard let recoveryCid = Self.realtimeRecoveryScope(
                after: result,
                groupCid: groupCid
            ), case .failure(let error) = result else { return }

            // Realtime application and protocol events travel through different rooms, so the
            // application event can arrive before the commit that advances this device to the
            // required epoch. Keep the encrypted MessageDTO as the durable retry source and ask
            // scope sync to merge protocol/application events in Bellboy's canonical order.
            //
            // Do not retry MLS directly or process the raw realtime commit here: both would race
            // the durable inbox/provider persistence path. `runSync` coalesces this scope when a
            // sync is already active, and a successful commit re-attempts pending ciphertexts.
            log.error(
                "[MLS] state=realtime_decrypt_failed action=request_scope_recovery "
                    + PrivacySafeLogMetadata.errorFields(error),
                subsystems: .mls
            )
            self?.performE2eChannelSync(cid: recoveryCid)
        }
    }

    /// Keeps the realtime fast path local, but converts a failed decrypt into a durable scope-sync
    /// recovery request. Internal so the failure/success routing remains covered by regression
    /// tests without exposing it as SDK API.
    static func realtimeRecoveryScope(
        after result: Result<E2ePayload, Error>,
        groupCid: ChannelId
    ) -> ChannelId? {
        guard case .failure = result else { return nil }
        return groupCid
    }

    static func shouldSkipRealtimeDecrypt(
        isSentByCurrentUser: Bool,
        hasCachedPlaintext: Bool
    ) -> Bool {
        isSentByCurrentUser && hasCachedPlaintext
    }
    
    private func decryptUpdatedMessageEventIfNeeded(message: ChatMessage, cid: ChannelId) {
        guard let encryptedData = message.encryptedData else { return }
        // Skip re-decryption for the current user's own edits — the local
        // MessageDecryptDTO was already updated in MessageUpdater.editMessage().
        // MLS cannot decrypt ciphertext produced by the same device.
        if message.isSentByCurrentUser { return }
        log.debug("[MLS] state=updated_message_redecrypt_started has_epoch=\(message.mlsEpoch != nil)")
        reDecryptUpdatedMessage(
            messageId: message.id,
            encryptedData: encryptedData,
            cid: cid,
            receiveSource: .messageUpdate
        )
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
    /// Must run on `MlsMutationExecutor`.
    private func reDecryptUpdatedMessageSync(
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        receiveSource: E2eeAttachmentReceiveSource
    ) {
        do {
            let group = try mlsClient.loadGroup(with: mlsGroupCid(for: cid).rawValue)
            let processed = try mlsClient.processApplicationMessage(data: encryptedData, in: group)
            _ = try persistProcessedApplicationMessage(
                processed,
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                group: group,
                receiveSource: receiveSource
            )
        } catch {
            // Unchanged/already-consumed ciphertext (a non-edit update) or an own-device message:
            // keep the existing decrypted cache rather than regressing to the placeholder.
            log.debug(
                "[MLS] state=updated_message_redecrypt_skipped reason=unchanged_or_consumed "
                    + PrivacySafeLogMetadata.errorFields(error),
                subsystems: .mls
            )
            hydrateDurablePayloadIfPresent(
                messageId: messageId,
                cid: cid,
                source: receiveSource
            )
        }
    }

    /// Enqueues `reDecryptUpdatedMessageSync` on `MlsMutationExecutor`. Used by the WebSocket
    /// `message.updated` path, which is not already running on the executor.
    private func reDecryptUpdatedMessage(
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        receiveSource: E2eeAttachmentReceiveSource
    ) {
        let op = BlockOperation { [weak self] in
            self?.reDecryptUpdatedMessageSync(
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                receiveSource: receiveSource
            )
        }
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: mlsGroupCid(for: cid).rawValue)
    }

    /// Persists plaintext first and only then advances the OpenMLS receiver ratchet on disk.
    /// The two stores cannot share a transaction; replay recovery distinguishes a stale provider
    /// from an already-saved provider through `MlsError.MessageAlreadyConsumed`.
    @discardableResult
    private func persistProcessedApplicationMessage(
        _ processed: MlsProcessedApplicationMessage,
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        group: Group,
        receiveSource: E2eeAttachmentReceiveSource,
        expectedEnvelope: E2eeReceivedMessageEnvelope? = nil
    ) throws -> E2ePayload {
        let authenticatedPayload = try validatedPayload(
            processed.payload,
            processedAAD: processed.aad,
            messageId: messageId,
            cid: cid,
            expectedEnvelope: expectedEnvelope
        )
        let ciphertextHash = Data(SHA256.hash(data: encryptedData))
        try database.writeAndWait { session in
            try session.saveMessageDecrypt(
                payload: authenticatedPayload,
                messageId: messageId,
                ciphertextHash: ciphertextHash
            )
            let message = session.message(id: messageId)
            message?.text = authenticatedPayload.text
            message?.forwardCid = authenticatedPayload.authenticatedMetadata?.forwardCid
        }
        log.info("[MLS] application_checkpoint stage=decoded_committed result=stored", subsystems: .mls)
        try mlsClient.saveState(of: group)
        log.info("[MLS] application_checkpoint stage=provider_saved result=stored", subsystems: .mls)
        e2eeAttachmentReceiveCoordinator.hydratePreviews(
            payload: authenticatedPayload,
            messageId: messageId,
            cid: cid,
            source: receiveSource
        )
        return authenticatedPayload
    }

    private func validatedPayload(
        _ payload: E2ePayload,
        processedAAD: Data,
        messageId: MessageId,
        cid: ChannelId,
        expectedEnvelope: E2eeReceivedMessageEnvelope?
    ) throws -> E2ePayload {
        guard !processedAAD.isEmpty else {
            guard payload.e2eeAttachments.isEmpty,
                  expectedEnvelope?.requiresAAD != true else {
                throw E2eeMessageAADError.authenticatedMetadataMismatch
            }
            return payload.withAuthenticatedMetadata(nil)
        }

        let aad = try E2eeMessageAADV1.decoded(from: processedAAD)
        guard aad.isRequired,
              aad.cid == cid.rawValue,
              aad.e2eeGroupId == mlsGroupCid(for: cid).rawValue,
              aad.messageId.caseInsensitiveCompare(messageId) == .orderedSame else {
            throw E2eeMessageAADError.authenticatedMetadataMismatch
        }
        try payload.e2eeAttachments.verifyCanonicalAttachmentIds(aad.attachmentIds)
        if let expectedEnvelope {
            let canonicalEnvelopeIds = try E2eeMessageAADV1.canonicalAttachmentIds(
                expectedEnvelope.attachmentIds
            )
            guard expectedEnvelope.forwardCid == aad.forwardCid,
                  expectedEnvelope.forwardMessageId == aad.forwardMessageId,
                  expectedEnvelope.forwardParentCid == aad.forwardParentCid,
                  canonicalEnvelopeIds == aad.attachmentIds else {
                throw E2eeMessageAADError.authenticatedMetadataMismatch
            }
        }
        return payload.withAuthenticatedMetadata(.init(
            forwardCid: aad.forwardCid,
            forwardMessageId: aad.forwardMessageId,
            forwardParentCid: aad.forwardParentCid,
            attachmentIds: aad.attachmentIds
        ))
    }

    private func handleHealthCheckEvent(_ event: HealthCheckEvent) {
        // Health checks are periodic liveness signals. Full catch-up is triggered only by the
        // connection-state transition above; doing it here polls scope_sync on every pong.
        // The health payload is only a bounded wake-up hint. Inventory authority and the durable
        // demand generation come from GET /v1/e2ee/key_packages/count, matching Android.
        guard let remaining = event.keyPackagesRemaining,
              let target = event.keyPackageRefillTarget,
              let lowWatermark = event.keyPackageRefillLowWatermark,
              E2eeKeyPackageRefillPolicy.shouldReconcileHealthCheck(
                remaining: remaining,
                target: target,
                lowWatermark: lowWatermark
              )
        else {
            return
        }
        reconcileKeyPackageInventory(reason: "manual")
    }

    private func reconcileKeyPackageInventory(reason: String) {
        guard beginKeyPackageRefill() else { return }
        reconcileKeyPackageInventory(reason: reason, attempt: 0)
    }

    private func reconcileKeyPackageInventory(reason: String, attempt: Int) {
        apiClient.request(endpoint: .keyPackagesCount(reason: reason)) { [weak self] result in
            guard let self else { return }
            guard case let .success(inventory) = result else {
                self.completeKeyPackageRefill()
                log.error("[MLS] state=keypackage_refill_failed reason=inventory_transport", subsystems: .mls)
                return
            }
            guard let batchSize = E2eeKeyPackageRefillPolicy.batchSize(
                remaining: inventory.remaining,
                target: inventory.target,
                lowWatermark: inventory.lowWatermark,
                requestedDelta: inventory.requestedDelta,
                refillGeneration: inventory.refillGeneration
            ) else {
                self.completeKeyPackageRefill()
                log.error("[MLS] state=keypackage_refill_failed reason=contract", subsystems: .mls)
                return
            }
            guard batchSize > 0 else {
                self.completeKeyPackageRefill()
                return
            }
            // Recount after the final upload even when its ACK was lost; the
            // generation budget remains five batches.
            guard attempt < E2eeKeyPackageRefillPolicy.maximumAttempts else {
                self.completeKeyPackageRefill()
                log.warning("[MLS] state=keypackage_refill_pending reason=attempts_exhausted", subsystems: .mls)
                return
            }

            let keyPackages: [[UInt8]]
            do {
                keyPackages = try self.performMlsMutation(cidString: "__identity__") {
                    try self.mlsClient.getKeyPackage(count: batchSize).map(\.uint8Array)
                }
            } catch {
                self.completeKeyPackageRefill()
                log.error(
                    "[MLS] state=keypackage_refill_failed reason=generation",
                    subsystems: .mls
                )
                return
            }

            self.apiClient.request(endpoint: .uploadKeyPackages(keyPackages: keyPackages)) {
                [weak self] uploadResult in
                guard let self else { return }
                switch uploadResult {
                case .success:
                    self.reconcileKeyPackageInventory(reason: reason, attempt: attempt + 1)
                case .failure:
                    let delay = E2eeKeyPackageRefillPolicy.retryBaseDelay
                        * pow(2, Double(attempt))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.reconcileKeyPackageInventory(reason: reason, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    private func beginKeyPackageRefill() -> Bool {
        keyPackageRefillStateQueue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            guard !keyPackageRefillInFlight,
                  keyPackageRefillCompletedAtUptime == 0
                    || now - keyPackageRefillCompletedAtUptime >= E2eeKeyPackageRefillPolicy.cooldown
            else {
                return false
            }
            keyPackageRefillInFlight = true
            return true
        }
    }

    private func completeKeyPackageRefill() {
        keyPackageRefillStateQueue.sync {
            keyPackageRefillInFlight = false
            keyPackageRefillCompletedAtUptime = ProcessInfo.processInfo.systemUptime
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
    /// 1. Durable fetch cursor from Core Data.
    /// 2. Legacy cursor in UserDefaults during migration.
    /// 3. MLS join/member/login boundary for a first sync.
    ///
    /// Returns `nil` when no cursor can be determined (e.g. the device hasn't joined the MLS group yet).
    private func resolveSyncCursor(cidString: String, mlsJoinedAt: NSDate?, memberCreatedAt: NSDate?, deviceLoginTime: Date?) -> ScopeSyncCursorPayload? {
        if let accountId = mlsClient.userId {
            do {
                if let durableCursor = try durableInboxStore.fetchCursor(
                    accountId: accountId,
                    scopeCid: cidString
                ) {
                    return durableCursor
                }
            } catch {
                log.error(
                    "[E2eSync] state=fetch_cursor_read_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
                return nil
            }
        }

        // Legacy migration fallback. Once a durable cursor exists it is authoritative.
        if let savedCursor = e2eSyncCursor(for: cidString) {
            if let memberCreatedAt,
               let savedDate = Self.parseRemovedAt(savedCursor.createdAt),
               memberCreatedAt.timeIntervalSince1970 > savedDate.timeIntervalSince1970 {
                // Kicked then re-added: membership is newer than the saved cursor. Drop the
                // stale local group and restart from the new membership boundary.
                if (try? mlsClient.loadGroup(with: cidString)) != nil {
                    do {
                        try performMlsMutation(cidString: cidString) {
                            try self.mlsClient.deleteGroup(cid: cidString)
                        }
                    } catch {
                        log.error(
                            "[MLS] state=group_delete_failed reason=user_removed "
                                + PrivacySafeLogMetadata.errorFields(error),
                            subsystems: .mls
                        )
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
    func performE2eSync(trigger: String = "explicit") {
        reconcilePendingGroupInfoRepairs()
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
                        self.performE2eSyncNow(trigger: trigger)
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
            self.performE2eSyncNow(trigger: trigger)
        }
    }

    /// Fetches all missed E2EE events for every MLS-enabled channel since the last known cursor,
    /// applying protocol messages and decrypting application messages in order.
    private func performE2eSyncNow(trigger: String) {
        syncLock.lock()
        guard !isSyncing else {
            syncLock.unlock()
            log.debug("[E2eSync] mode=full state=coalesced trigger=\(trigger)", subsystems: .mls)
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
        syncLock.lock()
        activeSyncCids = Set(cursors.keys)
        syncLock.unlock()
        log.debug(
            "[E2eSync] mode=full state=started trigger=\(trigger) scope_count=\(cursors.count)",
            subsystems: .mls
        )
        replayDurablePendingEvents(scopeCids: Set(cursors.keys))
        startSyncPages(cursors: cursors)
    }
    
    /// Called after a channel list API response is saved to the database.
    /// For each MLS-enabled channel whose local MLS group does not yet exist,
    /// performs an external join so the device can decrypt messages in that channel.
    /// For channels whose group already exists locally (e.g. MLS DB survived logout),
    /// ensures `mlsGroupJoinedAt` is set so E2E sync has a valid cursor.
    ///
    /// - Parameter cids: The MLS-enabled channel IDs from the saved channel list payload.
    func handleNewEncryptedChannels(_ cids: [ChannelId]) {
        let resolved = Dictionary(grouping: cids.map(mlsGroupCid(for:)), by: \.rawValue)
            .compactMap { $0.value.first }
        let candidates = resolved.filter {
            guard let state = trackedReadiness(for: $0.rawValue) else { return true }
            return ![.ready, .recovered, .historyIncomplete].contains(state)
        }
        let existing = candidates.filter {
            mlsClient.isGroupLoaded(cid: $0.rawValue) && !hasLocalJoinReceipt(for: $0.rawValue)
        }
        let missing = candidates.filter {
            !mlsClient.isGroupLoaded(cid: $0.rawValue) || hasLocalJoinReceipt(for: $0.rawValue)
        }

        existing.forEach { setReadiness(.restoring, for: $0.rawValue) }

        // Existing groups use bounded batches; missing groups keep the exact Web state machine
        // and are serialized below (pre-sync -> Welcome or external join -> post-sync).
        let startBootstrap = { [weak self] in
            guard let self else { return }
            self.syncExistingGroupsInBatches(Array(existing), batchSize: 20) { [weak self] in
                missing.forEach { self?.enqueueBootstrap(for: $0) }
            }
        }
        guard !existing.isEmpty else {
            startBootstrap()
            return
        }
        database.write { session in
            for cid in existing {
                guard let dto = session.channel(cid: cid), dto.mlsGroupJoinedAt == nil else { continue }
                dto.mlsGroupJoinedAt = Date().bridgeDate
            }
        } completion: { error in
            if let error {
                log.error(
                    "[E2eSync] state=join_anchor_persist_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
            }
            startBootstrap()
        }
    }

    func readiness(for cid: ChannelId) -> E2eeChannelReadiness {
        let groupCid = mlsGroupCid(for: cid).rawValue
        readinessLock.lock()
        let state = readinessByCid[groupCid]
        readinessLock.unlock()
        if let state { return state }
        return mlsClient.isGroupLoaded(cid: groupCid) ? .ready : .restoring
    }

    func ensureE2eeReady(
        for cid: ChannelId,
        completion: @escaping (E2eeChannelReadiness) -> Void
    ) {
        let groupCid = mlsGroupCid(for: cid)
        let current = readiness(for: groupCid)
        if current == .ready || current == .recovered || current == .historyIncomplete {
            completion(current)
            return
        }
        readinessLock.lock()
        readinessCallbacks[groupCid.rawValue, default: []].append(completion)
        readinessLock.unlock()
        enqueueBootstrap(for: groupCid)
    }

    private func syncExistingGroupsInBatches(
        _ cids: [ChannelId],
        batchSize: Int,
        completion: @escaping () -> Void
    ) {
        guard !cids.isEmpty else {
            completion()
            return
        }
        let batch = Array(cids.prefix(batchSize))
        let remaining = Array(cids.dropFirst(batch.count))
        batch.forEach { setReadiness(.syncing, for: $0.rawValue) }
        performE2eChannelSync(cids: Set(batch.map(\.rawValue))) { [weak self] in
            guard let self else { return }
            self.recoverRetainedGroups(Array(batch)) { [weak self] in
                guard let self else { return }
                for cid in batch {
                    self.setReadiness(self.bootstrapCompletionState(for: cid), for: cid.rawValue)
                }
                self.syncExistingGroupsInBatches(remaining, batchSize: batchSize, completion: completion)
            }
        }
    }

    private func hasRetainedReplayBlock(_ cid: String) -> Bool {
        retainedReplayLock.lock()
        defer { retainedReplayLock.unlock() }
        return retainedReplayBlockedCids.contains(cid)
    }

    private func setRetainedReplayBlock(_ cid: String, blocked: Bool) {
        retainedReplayLock.lock()
        defer { retainedReplayLock.unlock() }
        if blocked { retainedReplayBlockedCids.insert(cid) }
        else { retainedReplayBlockedCids.remove(cid) }
    }

    private func recoverRetainedGroups(_ cids: [ChannelId], completion: @escaping () -> Void) {
        guard let cid = cids.first else { completion(); return }
        recoverRetainedGroupIfBehind(cid: cid) { [weak self] in
            self?.recoverRetainedGroups(Array(cids.dropFirst()), completion: completion)
        }
    }

    private func recoverRetainedGroupIfBehind(cid: ChannelId, completion: @escaping () -> Void) {
        guard mlsRolloutControls.historicalReplayEnabled,
              !hasLocalJoinReceipt(for: cid.rawValue),
              loadMlsRebootstrapCheckpoint(cid: cid.rawValue) == nil,
              let group = try? mlsClient.loadGroup(with: cid.rawValue) else {
            completion(); return
        }
        var serverEpoch = 0
        let readContext = database.backgroundReadOnlyContext
        readContext.performAndWait {
            serverEpoch = ChannelDTO.load(cid: cid, context: readContext)?.mlsEpoch ?? 0
        }
        guard group.epoch() < UInt64(max(0, serverEpoch)) || isScopeBlocked(cid.rawValue) else {
            completion(); return
        }
        apiClient.request(endpoint: .mlsGeneration(cid: cid)) { [weak self] result in
            guard let self else { return }
            guard case .success(let state) = result,
                  state.isValidIdentity(installedGeneration: self.groupGeneration(for: cid)),
                  state.groupGeneration == self.groupGeneration(for: cid),
                  state.capability.protocolVersion == MlsRebootstrapCapabilityPayload.currentProtocolVersion,
                  state.currentEpoch > Int(group.epoch()) else { completion(); return }
            self.replayRetainedCommits(cid: cid, generation: state.groupGeneration,
                targetEpoch: state.currentEpoch,
                cursor: .init(createdAt: "1970-01-01T00:00:00.000000Z", eventId: Self.zeroEventId),
                pagesRemaining: 10) { [weak self] in
                    guard let self else { return }
                    let localEpoch = (try? self.mlsClient.loadGroup(with: cid.rawValue).epoch()) ?? 0
                    guard self.hasRetainedReplayBlock(cid.rawValue), localEpoch < UInt64(state.currentEpoch) else {
                        completion(); return
                    }
                    self.externalJoinChannel(cid: cid, requiresActiveMemberRecovery: true, replaceRetainedGroup: true) { error in
                        if error == nil {
                            self.setRetainedReplayBlock(cid.rawValue, blocked: false)
                            self.scheduleDurableDrain(cid: cid, cidString: cid.rawValue, resetProtocolBlock: true)
                        }
                        completion()
                    }
                }
        }
    }

    private func replayRetainedCommits(
        cid: ChannelId, generation: Int, targetEpoch: Int,
        cursor: ScopeSyncCursorPayload, pagesRemaining: Int, completion: @escaping () -> Void
    ) {
        guard pagesRemaining > 0, let accountId = mlsClient.userId else { completion(); return }
        apiClient.request(endpoint: .e2eSync(body: .init(cursors: [cid.rawValue: cursor], limit: 100))) { [weak self] result in
            guard let self else { return }
            guard case .success(let payload) = result, let page = payload.channels[cid.rawValue] else {
                completion(); return
            }
            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                do {
                    for event in page.events {
                        guard case .protocol(let data) = event.event,
                              data.groupGeneration == generation,
                              [.commit, .externalCommit].contains(data.type) else { continue }
                        let localEpoch = try self.mlsClient.loadGroup(with: cid.rawValue).epoch()
                        guard data.epoch > Int(localEpoch), data.epoch <= targetEpoch else { continue }
                        guard data.epoch == Int(localEpoch) + 1 else {
                            throw E2eeSyncApplyError.epochMismatch(local: localEpoch, event: data.epoch)
                        }
                        _ = try self.durableInboxStore.persistPage(accountId: accountId,
                            scopeCid: cid.rawValue, events: [event], hasMore: false, nextCursor: nil)
                        _ = try self.processSingleE2eSyncEvent(event, accountId: accountId,
                            cid: cid, cidString: cid.rawValue)
                        try self.durableInboxStore.markRecoveredCommitApplied(accountId: accountId,
                            scopeCid: cid.rawValue, eventId: event.eventId)
                    }
                    let localEpoch = try self.mlsClient.loadGroup(with: cid.rawValue).epoch()
                    if localEpoch >= UInt64(targetEpoch) {
                        log.info("[MLS] retained_recovery result=caught_up", subsystems: .mls)
                        self.scheduleDurableDrain(cid: cid, cidString: cid.rawValue, resetProtocolBlock: true)
                        let barrier = BlockOperation { completion() }
                        self.enqueueGroupOperation(barrier, cidString: cid.rawValue)
                    } else if page.hasMore, let next = page.nextCursor, next != cursor {
                        self.replayRetainedCommits(cid: cid, generation: generation, targetEpoch: targetEpoch,
                            cursor: next, pagesRemaining: pagesRemaining - 1, completion: completion)
                    } else {
                        log.warning("[MLS] retained_recovery result=history_gap", subsystems: .mls)
                        completion()
                    }
                } catch {
                    if error is MlsError || error is E2eeSyncApplyError {
                        self.setRetainedReplayBlock(cid.rawValue, blocked: true)
                    }
                    log.error("[MLS] retained_recovery result=blocked " + PrivacySafeLogMetadata.errorFields(error), subsystems: .mls)
                    completion()
                }
            }
            self.enqueueGroupOperation(operation, cidString: cid.rawValue)
        }
    }

    private func enqueueBootstrap(for cid: ChannelId) {
        let shouldStart = bootstrapQueue.enqueue(cid)
        if shouldStart { runNextBootstrap() }
    }

    private func runNextBootstrap() {
        guard let cid = bootstrapQueue.dequeue() else { return }

        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        trace.info(
            stage: "bootstrap_started",
            source: "bootstrap",
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            readiness: E2eeChannelReadiness.syncing.rawValue,
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue)
        )
        setReadiness(.syncing, for: cid.rawValue)
        if mlsClient.isGroupLoaded(cid: cid.rawValue), !hasLocalJoinReceipt(for: cid.rawValue) {
            recoverRetainedGroupIfBehind(cid: cid) { [weak self] in
                guard let self else { return }
                self.performE2eChannelSync(cids: [cid.rawValue]) {
                    self.finishBootstrap(cid: cid, state: self.bootstrapCompletionState(for: cid))
                }
            }
            return
        }
        apiClient.request(endpoint: .mlsGeneration(cid: cid)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let state):
                guard state.capability.protocolVersion
                        == MlsRebootstrapCapabilityPayload.currentProtocolVersion,
                      state.capability.repairTimeoutSeconds == 15 * 60 else {
                    self.finishBootstrap(cid: cid, state: .clientUpgradeRequired)
                    return
                }
                if let checkpoint = self.loadMlsRebootstrapCheckpoint(cid: cid.rawValue) {
                    self.setReadiness(.rebootstrapping, for: cid.rawValue)
                    self.reconcileMlsRebootstrapCheckpoint(
                        checkpoint,
                        cid: cid,
                        trace: trace,
                        retryCompleteIfMissing: true
                    )
                    return
                }
                let localGeneration = Int(
                    self.mlsClient.loadGenerationMarker(cid: cid.rawValue)?.generation ?? 0
                )
                guard state.isValidIdentity(installedGeneration: localGeneration) else {
                    self.finishBootstrap(cid: cid, state: .infrastructureRetryable)
                    return
                }
                if state.requiresAuthoritativeJoin(
                    installedGeneration: localGeneration,
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                ) {
                    self.externalJoinAuthoritativeGeneration(cid: cid, trace: trace)
                    return
                }
                if state.state == .eligible, state.capability.automaticEnabled {
                    if self.mlsClient.isGroupLoaded(cid: cid.rawValue) {
                        self.repairGroupInfoBeforeRebootstrap(cid: cid, trace: trace)
                    } else {
                        self.beginMlsRebootstrap(cid: cid, state: state, trace: trace)
                    }
                    return
                }
                if [.repairing, .preparing].contains(state.state),
                   !self.mlsClient.isGroupLoaded(cid: cid.rawValue) {
                    self.finishBootstrap(cid: cid, state: .waitingForRepair)
                    return
                }
                if [.upgradeRequired, .incompatibleServerClient].contains(state.state) {
                    self.finishBootstrap(cid: cid, state: .clientUpgradeRequired)
                    return
                }
                if state.state == .activated {
                    self.removeMlsRebootstrapClaimIntent(cid: cid.rawValue)
                }
                self.continueBootstrapAfterGenerationDiscovery(cid: cid, trace: trace)
            case .failure(let error):
                self.finishBootstrap(
                    cid: cid,
                    state: E2eeMlsRebootstrapFailureClassifier.readiness(for: error)
                )
            }
        }
    }

    private func continueBootstrapAfterGenerationDiscovery(
        cid: ChannelId,
        trace: E2eeJoinTrace.Context
    ) {
        performE2eChannelSync(cids: Set([cid.rawValue])) { [weak self] in
            guard let self else { return }
            let groupLoaded = self.mlsClient.isGroupLoaded(cid: cid.rawValue)
            let hasReceipt = self.hasLocalJoinReceipt(for: cid.rawValue)
            trace.info(
                stage: "bootstrap_presync_finished",
                source: "scope_sync",
                result: groupLoaded && !hasReceipt ? "group_ready" : "join_required",
                receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                groupLoaded: groupLoaded
            )
            if groupLoaded, !hasReceipt {
                self.finishBootstrap(cid: cid, state: self.bootstrapCompletionState(for: cid))
                return
            }

            guard let accountId = self.mlsClient.userId else {
                self.finishBootstrap(cid: cid, state: .needsRetry)
                return
            }
            let hasTypedPrerequisite: Bool
            do {
                hasTypedPrerequisite = try self.durableInboxStore
                    .hasNoMatchingKeyPackageJoinPrerequisite(
                        accountId: accountId,
                        scopeCid: cid.rawValue
                    )
            } catch {
                log.error(
                    "[E2E] state=external_join_blocked reason=join_prerequisite_unavailable",
                    subsystems: .mls
                )
                self.finishBootstrap(cid: cid, state: .needsRetry)
                return
            }
            guard self.mlsRolloutControls.partialWelcomeFallbackEnabled else {
                self.emitMlsRolloutMetric(.init(name: .externalJoinFallback, outcome: .disabled, reason: .rolloutDisabled))
                self.finishBootstrap(cid: cid, state: .needsRetry)
                return
            }
            let reason: E2eeMlsRolloutMetricReason = hasTypedPrerequisite ? .noMatchingKeyPackage : .activeMemberRecovery

            trace.info(
                stage: "external_join_selected",
                source: "bootstrap",
                receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                readiness: E2eeChannelReadiness.joining.rawValue,
                groupLoaded: groupLoaded
            )
            self.setReadiness(.joining, for: cid.rawValue)
            self.emitMlsRolloutMetric(
                .init(
                    name: .externalJoinFallback,
                    outcome: .attempt,
                    reason: reason
                )
            )
            self.externalJoinChannel(cid: cid, requiresActiveMemberRecovery: !hasTypedPrerequisite) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.emitMlsRolloutMetric(
                        .init(
                            name: .externalJoinFallback,
                            outcome: .failure,
                            reason: reason
                        )
                    )
                    trace.failure(
                        stage: "external_join_failed",
                        source: "bootstrap",
                        error: error,
                        receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                    )
                    log.error(
                        "[E2E] state=external_join_failed \(PrivacySafeLogMetadata.errorFields(error))",
                        subsystems: .mls
                    )
                    self.finishBootstrap(cid: cid, state: .failed)
                    return
                }
                self.emitMlsRolloutMetric(
                    .init(
                        name: .externalJoinFallback,
                        outcome: .success,
                        reason: reason
                    )
                )
                trace.info(
                    stage: "external_join_finished",
                    source: "bootstrap",
                    result: "post_sync_required",
                    receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                    readiness: E2eeChannelReadiness.syncing.rawValue,
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                )
                self.setReadiness(.syncing, for: cid.rawValue)
                self.performE2eChannelSync(cids: Set([cid.rawValue])) { [weak self] in
                    guard let self else { return }
                    trace.info(
                        stage: "bootstrap_postsync_finished",
                        source: "scope_sync",
                        receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                    )
                    self.finishBootstrap(cid: cid, state: self.bootstrapCompletionState(for: cid))
                }
            }
        }
    }

    private func externalJoinAuthoritativeGeneration(
        cid: ChannelId,
        trace: E2eeJoinTrace.Context
    ) {
        setReadiness(.joining, for: cid.rawValue)
        externalJoinChannel(cid: cid) { [weak self] error in
            guard let self else { return }
            if let error {
                trace.failure(
                    stage: "generation_external_join_failed",
                    source: "generation_state",
                    error: error,
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                )
                self.finishBootstrap(
                    cid: cid,
                    state: E2eeMlsRebootstrapFailureClassifier.readiness(for: error)
                )
                return
            }
            self.performE2eChannelSync(cids: Set([cid.rawValue])) { [weak self] in
                guard let self else { return }
                self.finishBootstrap(cid: cid, state: .recovered)
            }
        }
    }

    private func repairGroupInfoBeforeRebootstrap(
        cid: ChannelId,
        trace: E2eeJoinTrace.Context
    ) {
        do {
            let (groupInfo, epoch) = try performMlsMutation(cidString: cid.rawValue) {
                let group = try self.mlsClient.loadGroup(with: cid.rawValue)
                return (try self.mlsClient.exportGroupInfo(of: group), group.epoch())
            }
            uploadGroupInfo(in: cid, groupInfo: groupInfo, epoch: Int(epoch)) { [weak self] error in
                guard let self else { return }
                if let error {
                    trace.failure(
                        stage: "generation_repair_failed",
                        source: "generation_state",
                        error: error,
                        groupLoaded: true
                    )
                    self.finishBootstrap(cid: cid, state: .infrastructureRetryable)
                } else {
                    self.continueBootstrapAfterGenerationDiscovery(cid: cid, trace: trace)
                }
            }
        } catch {
            trace.failure(
                stage: "generation_repair_export_failed",
                source: "generation_state",
                error: error,
                groupLoaded: true
            )
            finishBootstrap(cid: cid, state: .infrastructureRetryable)
        }
    }

    private func beginMlsRebootstrap(
        cid: ChannelId,
        state: MlsGenerationStatePayload,
        trace: E2eeJoinTrace.Context
    ) {
        setReadiness(.rebootstrapping, for: cid.rawValue)
        if let checkpoint = loadMlsRebootstrapCheckpoint(cid: cid.rawValue) {
            reconcileMlsRebootstrapCheckpoint(
                checkpoint,
                cid: cid,
                trace: trace,
                retryCompleteIfMissing: true
            )
            return
        }
        let operationKey: String
        if let intent = loadMlsRebootstrapClaimIntent(cid: cid.rawValue),
           intent.matches(cid: cid.rawValue, state: state) {
            operationKey = intent.operationKey
        } else {
            removeMlsRebootstrapClaimIntent(cid: cid.rawValue)
            let intent = E2eeMlsRebootstrapClaimIntent(
                cid: cid.rawValue,
                operationKey: UUID().uuidString.lowercased(),
                expectedGeneration: state.groupGeneration,
                expectedEpoch: state.currentEpoch,
                protocolVersion: MlsRebootstrapCapabilityPayload.currentProtocolVersion
            )
            do {
                try saveMlsRebootstrapClaimIntent(intent)
                operationKey = intent.operationKey
            } catch {
                trace.failure(
                    stage: "rebootstrap_claim_intent_failed",
                    source: "generation_state",
                    error: error,
                    groupLoaded: false
                )
                finishBootstrap(cid: cid, state: .infrastructureRetryable)
                return
            }
        }
        let request = ClaimMlsRebootstrapRequestBody(
            operationKey: operationKey,
            expectedGeneration: state.groupGeneration,
            expectedEpoch: state.currentEpoch,
            protocolVersion: MlsRebootstrapCapabilityPayload.currentProtocolVersion
        )
        apiClient.request(endpoint: .claimMlsRebootstrap(cid: cid, body: request)) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let claim):
                guard claim.operationKey == operationKey,
                      claim.expectedGeneration == state.groupGeneration,
                      claim.expectedEpoch == state.currentEpoch,
                      claim.nextGeneration == state.groupGeneration + 1,
                      claim.state == .preparing else {
                    self.finishBootstrap(cid: cid, state: .infrastructureRetryable)
                    return
                }
                self.prepareAndCompleteMlsRebootstrap(
                    cid: cid,
                    claim: claim,
                    capability: state.capability,
                    trace: trace
                )
            case .failure(let error):
                trace.failure(
                    stage: "rebootstrap_claim_failed",
                    source: "generation_state",
                    error: error,
                    groupLoaded: false
                )
                self.finishBootstrap(
                    cid: cid,
                    state: E2eeMlsRebootstrapFailureClassifier.readiness(for: error)
                )
            }
        }
    }

    private func prepareAndCompleteMlsRebootstrap(
        cid: ChannelId,
        claim: MlsRebootstrapClaimPayload,
        capability: MlsRebootstrapCapabilityPayload,
        trace: E2eeJoinTrace.Context
    ) {
        do {
            var selected = Array(
                claim.recipientKeyPackages.prefix(capability.maxWelcomeRecipients)
            )
            var candidate: MlsRebootstrapCandidate
            while true {
                let candidateId = UUID().uuidString.lowercased()
                let groupId = randomMlsGroupId()
                candidate = try performMlsMutation(cidString: cid.rawValue) {
                    try self.mlsClient.prepareRebootstrapCandidate(
                        operationId: candidateId,
                        groupId: groupId,
                        keyPackages: selected.map { Data($0.keyPackage) }
                    )
                }
                let withinLimits = candidate.groupInfo.count <= capability.maxGroupInfoBytes
                    && candidate.ratchetTree.count <= capability.maxRatchetTreeBytes
                    && (candidate.welcome?.count ?? 0) <= capability.maxWelcomeBytes
                if withinLimits { break }
                try mlsClient.removeRebootstrapCandidate(at: candidate.providerPath)
                guard !selected.isEmpty else {
                    throw ClientError.Unexpected(
                        "MLS rebootstrap public artifacts exceed negotiated limits."
                    )
                }
                selected.removeLast(max(1, selected.count / 4))
            }
            let body = CompleteMlsRebootstrapRequestBody(
                operationId: claim.operationId,
                operationKey: claim.operationKey,
                leaseToken: claim.leaseToken,
                expectedGeneration: claim.expectedGeneration,
                expectedEpoch: claim.expectedEpoch,
                newGeneration: claim.nextGeneration,
                newEpoch: Int(candidate.epoch),
                membershipVersion: claim.membershipVersion,
                groupId: candidate.groupId.uint8Array,
                groupInfo: candidate.groupInfo.uint8Array,
                ratchetTree: candidate.ratchetTree.uint8Array,
                welcome: candidate.welcome?.uint8Array,
                recipients: selected.map {
                    .init(
                        userId: $0.userId,
                        deviceId: $0.deviceId,
                        keyPackageId: $0.keyPackageId
                    )
                }
            )
            let checkpoint = E2eeMlsRebootstrapCheckpoint(
                cid: cid.rawValue,
                providerPath: candidate.providerPath,
                completeBody: body
            )
            try saveMlsRebootstrapCheckpoint(checkpoint)
            removeMlsRebootstrapClaimIntent(cid: cid.rawValue)
            completeMlsRebootstrap(checkpoint, candidate: candidate, cid: cid, trace: trace)
        } catch {
            trace.failure(
                stage: "rebootstrap_preparation_failed",
                source: "generation_state",
                error: error,
                groupLoaded: false
            )
            finishBootstrap(cid: cid, state: .infrastructureRetryable)
        }
    }

    private func completeMlsRebootstrap(
        _ checkpoint: E2eeMlsRebootstrapCheckpoint,
        candidate: MlsRebootstrapCandidate,
        cid: ChannelId,
        trace: E2eeJoinTrace.Context
    ) {
        apiClient.request(
            endpoint: .completeMlsRebootstrap(cid: cid, body: checkpoint.completeBody)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let receipt):
                self.applyMlsRebootstrapReceipt(
                    receipt,
                    checkpoint: checkpoint,
                    candidate: candidate,
                    cid: cid,
                    trace: trace
                )
            case .failure(let error):
                self.reconcileMlsRebootstrapCheckpoint(
                    checkpoint,
                    cid: cid,
                    trace: trace,
                    retryCompleteIfMissing: false,
                    fallbackError: error
                )
            }
        }
    }

    private func reconcileMlsRebootstrapCheckpoint(
        _ checkpoint: E2eeMlsRebootstrapCheckpoint,
        cid: ChannelId,
        trace: E2eeJoinTrace.Context,
        retryCompleteIfMissing: Bool,
        fallbackError: Error? = nil
    ) {
        apiClient.request(
            endpoint: .mlsRebootstrapReceipt(
                cid: cid,
                operationId: checkpoint.completeBody.operationId
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let receipt):
                let candidate = MlsRebootstrapCandidate(
                    providerPath: checkpoint.providerPath,
                    groupId: Data(checkpoint.completeBody.groupId),
                    epoch: UInt64(checkpoint.completeBody.newEpoch),
                    groupInfo: Data(checkpoint.completeBody.groupInfo),
                    ratchetTree: Data(checkpoint.completeBody.ratchetTree),
                    welcome: checkpoint.completeBody.welcome.map { Data($0) }
                )
                self.applyMlsRebootstrapReceipt(
                    receipt,
                    checkpoint: checkpoint,
                    candidate: candidate,
                    cid: cid,
                    trace: trace
                )
            case .failure(let error):
                guard retryCompleteIfMissing else {
                    self.finishBootstrap(
                        cid: cid,
                        state: E2eeMlsRebootstrapFailureClassifier.readiness(
                            for: fallbackError ?? error
                        )
                    )
                    return
                }
                let candidate = MlsRebootstrapCandidate(
                    providerPath: checkpoint.providerPath,
                    groupId: Data(checkpoint.completeBody.groupId),
                    epoch: UInt64(checkpoint.completeBody.newEpoch),
                    groupInfo: Data(checkpoint.completeBody.groupInfo),
                    ratchetTree: Data(checkpoint.completeBody.ratchetTree),
                    welcome: checkpoint.completeBody.welcome.map { Data($0) }
                )
                self.completeMlsRebootstrap(
                    checkpoint,
                    candidate: candidate,
                    cid: cid,
                    trace: trace
                )
            }
        }
    }

    private func applyMlsRebootstrapReceipt(
        _ receipt: MlsRebootstrapReceiptPayload,
        checkpoint: E2eeMlsRebootstrapCheckpoint,
        candidate: MlsRebootstrapCandidate,
        cid: ChannelId,
        trace: E2eeJoinTrace.Context
    ) {
        do {
            switch receipt.state {
            case .activated, .deliveryFailedRetryable:
                guard receipt.operationId == checkpoint.completeBody.operationId,
                      receipt.currentGeneration == checkpoint.completeBody.newGeneration,
                      receipt.currentEpoch == checkpoint.completeBody.newEpoch,
                      receipt.groupId == checkpoint.completeBody.groupId else {
                    throw ClientError.Unexpected("MLS rebootstrap receipt binding mismatch.")
                }
                try performMlsMutation(cidString: cid.rawValue) {
                    try self.mlsClient.activateRebootstrapCandidate(
                        cid: cid.rawValue,
                        generation: UInt64(receipt.currentGeneration),
                        operationId: receipt.operationId,
                        candidate: candidate
                    )
                }
                removeMlsRebootstrapCheckpoint(cid: cid.rawValue)
                removeMlsRebootstrapClaimIntent(cid: cid.rawValue)
                finishBootstrap(
                    cid: cid,
                    state: receipt.reason == .historyIncomplete ? .historyIncomplete : .recovered
                )
            case .cancelledRepairWon:
                try mlsClient.removeRebootstrapCandidate(at: checkpoint.providerPath)
                removeMlsRebootstrapCheckpoint(cid: cid.rawValue)
                removeMlsRebootstrapClaimIntent(cid: cid.rawValue)
                continueBootstrapAfterGenerationDiscovery(cid: cid, trace: trace)
            default:
                finishBootstrap(
                    cid: cid,
                    state: receipt.retryable ? .infrastructureRetryable : .clientUpgradeRequired
                )
            }
        } catch {
            trace.failure(
                stage: "rebootstrap_receipt_apply_failed",
                source: "operation_receipt",
                error: error,
                groupLoaded: false
            )
            finishBootstrap(cid: cid, state: .infrastructureRetryable)
        }
    }

    private func randomMlsGroupId() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func mlsRebootstrapCheckpointKey(cid: String) -> String {
        let accountId = mlsClient.userId ?? "missing-account"
        let accountDigest = SHA256.hash(data: Data(accountId.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let cidDigest = SHA256.hash(data: Data(cid.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "ermis_mls_rebootstrap_checkpoint_v1:" + accountDigest + ":" + cidDigest
    }

    private func mlsRebootstrapClaimIntentKey(cid: String) -> String {
        "ermis_mls_rebootstrap_claim_intent_v1:" + mlsRebootstrapCheckpointKey(cid: cid)
    }

    private func loadMlsRebootstrapClaimIntent(cid: String) -> E2eeMlsRebootstrapClaimIntent? {
        guard let data = mlsClient.userDefaults.data(
            forKey: mlsRebootstrapClaimIntentKey(cid: cid)
        ) else { return nil }
        return try? JSONDecoder().decode(E2eeMlsRebootstrapClaimIntent.self, from: data)
    }

    private func saveMlsRebootstrapClaimIntent(
        _ intent: E2eeMlsRebootstrapClaimIntent
    ) throws {
        mlsClient.userDefaults.set(
            try JSONEncoder().encode(intent),
            forKey: mlsRebootstrapClaimIntentKey(cid: intent.cid)
        )
    }

    private func removeMlsRebootstrapClaimIntent(cid: String) {
        mlsClient.userDefaults.removeObject(forKey: mlsRebootstrapClaimIntentKey(cid: cid))
    }

    private func loadMlsRebootstrapCheckpoint(cid: String) -> E2eeMlsRebootstrapCheckpoint? {
        guard let data = mlsClient.userDefaults.data(
            forKey: mlsRebootstrapCheckpointKey(cid: cid)
        ) else { return nil }
        return try? JSONDecoder().decode(E2eeMlsRebootstrapCheckpoint.self, from: data)
    }

    private func saveMlsRebootstrapCheckpoint(
        _ checkpoint: E2eeMlsRebootstrapCheckpoint
    ) throws {
        let data = try JSONEncoder().encode(checkpoint)
        mlsClient.userDefaults.set(
            data,
            forKey: mlsRebootstrapCheckpointKey(cid: checkpoint.cid)
        )
    }

    private func removeMlsRebootstrapCheckpoint(cid: String) {
        mlsClient.userDefaults.removeObject(forKey: mlsRebootstrapCheckpointKey(cid: cid))
    }

    private func bootstrapCompletionState(for cid: ChannelId) -> E2eeChannelReadiness {
        if isScopeBlocked(cid.rawValue) { return .needsRetry }
        guard mlsClient.isGroupLoaded(cid: cid.rawValue) else { return .failed }
        // This remains a lifecycle/sync UI state. `encryptedMessage` independently evaluates
        // crypto safety, so a merged exact receipt may send while post-sync reconciles.
        if hasLocalJoinReceipt(for: cid.rawValue) { return .needsRetry }
        return .ready
    }

    private func finishBootstrap(cid: ChannelId, state: E2eeChannelReadiness) {
        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        setReadiness(state, for: cid.rawValue)
        let needsCatchUp = bootstrapQueue.finish(cid)
        trace.info(
            stage: "bootstrap_finished",
            source: "bootstrap",
            result: state.rawValue,
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            readiness: state.rawValue,
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
            deferredSync: needsCatchUp
        )
        // An invite/WebSocket hint that arrived during pre-sync → join → post-sync must not
        // start a competing scope sync. Coalesce it into exactly one catch-up before starting
        // the next serialized external-join mutation.
        guard needsCatchUp else {
            runNextBootstrap()
            return
        }
        performE2eChannelSync(cids: Set([cid.rawValue])) { [weak self] in
            self?.runNextBootstrap()
        }
    }

    private func setReadiness(_ state: E2eeChannelReadiness, for cidString: String) {
        readinessLock.lock()
        readinessByCid[cidString] = state
        let terminalStates: Set<E2eeChannelReadiness> = [
            .ready,
            .recovered,
            .historyIncomplete,
            .clientUpgradeRequired,
            .infrastructureRetryable,
            .waitingForRepair,
            .needsRetry,
            .failed,
        ]
        let callbacks = terminalStates.contains(state)
            ? readinessCallbacks.removeValue(forKey: cidString) ?? []
            : []
        readinessLock.unlock()
        E2eeJoinTrace.Context(cid: cidString).info(
            stage: "readiness_changed",
            source: "readiness",
            receipt: joinReceiptTraceStatus(for: cidString),
            readiness: state.rawValue,
            groupLoaded: mlsClient.isGroupLoaded(cid: cidString)
        )
        log.debug("[E2EReadiness] state=\(state.rawValue)", subsystems: .mls)
        callbacks.forEach { $0(state) }
    }

    private func trackedReadiness(for cidString: String) -> E2eeChannelReadiness? {
        readinessLock.lock()
        let state = readinessByCid[cidString]
        readinessLock.unlock()
        return state
    }

    private func isScopeBlocked(_ cidString: String) -> Bool {
        durableApplyLock.lock()
        let blocked = blockedDurableScopes.contains(cidString)
        durableApplyLock.unlock()
        return blocked
    }

    private func hasLocalJoinReceipt(for cidString: String) -> Bool {
        guard let accountId = mlsClient.userId else { return false }
        do {
            let finalized = try durableInboxStore.finalizeAppliedLocalJoinReceiptIfPossible(
                accountId: accountId,
                scopeCid: cidString
            )
            if finalized, let cid = try? ChannelId(cid: cidString) {
                normalizeHistoricalApplications(cid: cid)
                retryPendingGroupApplications(in: cid)
            }
            return try durableInboxStore.localJoinReceiptProof(
                accountId: accountId,
                scopeCid: cidString
            ) != nil
        } catch {
            // Fail closed: inability to verify durable join proof must never open the send gate.
            log.error(
                "[E2EReadiness] state=needsRetry reason=join_receipt_unavailable",
                subsystems: .mls
            )
            return true
        }
    }

    private func joinReceiptTraceStatus(for cidString: String) -> String {
        guard let accountId = mlsClient.userId else { return "no_account" }
        do {
            return try durableInboxStore.localJoinReceiptProof(
                accountId: accountId,
                scopeCid: cidString
            )?.status.rawValue ?? "none"
        } catch {
            return "unavailable"
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
        runSync(forCidStrings: [cid.rawValue], completion: nil)
    }

    /// Synchronizes the canonical MLS scope after Bellboy rejected an exact application-message
    /// intent as stale. Completion runs only after the sync pagination and queued MLS/Core Data
    /// apply barrier finish. The caller may then generate one replacement ciphertext while
    /// retaining the same logical message ID and envelope metadata.
    func recoverMessageEpoch(
        in cid: ChannelId,
        minimumEpoch: Int64,
        completion: @escaping (Result<UInt64, Error>) -> Void
    ) {
        guard minimumEpoch >= 0 else {
            completion(.failure(E2eeMessageEpochRecoveryError.invalidRejection))
            return
        }
        let groupCid = mlsGroupCid(for: cid)
        runSync(forCidStrings: [groupCid.rawValue]) { [weak self] in
            guard let self else {
                completion(.failure(E2eeMessageEpochRecoveryError.ownerReleased))
                return
            }
            do {
                let group = try self.mlsClient.loadGroup(with: groupCid.rawValue)
                let localEpoch = UInt64(group.epoch())
                guard localEpoch >= UInt64(minimumEpoch) else {
                    completion(.failure(E2eeMessageEpochRecoveryError.scopeStillBehind(
                        local: localEpoch,
                        required: minimumEpoch
                    )))
                    return
                }
                guard self.canEncrypt(in: group, scopeCid: groupCid.rawValue) else {
                    completion(.failure(E2eeMessageEpochRecoveryError.scopeNotReady(
                        cid: groupCid.rawValue
                    )))
                    return
                }
                completion(.success(localEpoch))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func performE2eChannelSync(cids: Set<String>, completion: @escaping () -> Void) {
        runSync(forCidStrings: cids, completion: completion)
    }

    /// Runs an E2EE sync for a specific set of channels. If a sync is already in flight the
    /// requested channels are queued (`pendingChannelSyncCids`) and drained in `finishSync`, so a
    /// freshly accepted/received channel is synced as soon as the current sync ends instead of
    /// being dropped. Cursor resolution runs on a background context to avoid blocking the UI.
    private func runSync(forCidStrings cidStrings: Set<String>, completion: (() -> Void)?) {
        guard !cidStrings.isEmpty else { return }
        syncLock.lock()
        if isSyncing {
            pendingChannelSyncCids.formUnion(cidStrings)
            if let completion { pendingSyncCompletions.append(completion) }
            syncLock.unlock()
            log.debug(
                "[E2eSync] mode=scoped state=coalesced scope_count=\(cidStrings.count)",
                subsystems: .mls
            )
            return
        }
        isSyncing = true
        activeSyncCids = cidStrings
        if let completion { activeSyncCompletions = [completion] }
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
            log.debug(
                "[E2eSync] mode=scoped state=skipped reason=group_not_joined scope_count=\(cidStrings.count)",
                subsystems: .mls
            )
            return
        }
        log.debug("[E2eSync] Starting sync for \(cursors.count) channel(s)", subsystems: .mls)
        replayDurablePendingEvents(scopeCids: Set(cursors.keys))
        startSyncPages(cursors: cursors)
    }

    /// The backend returns at most 100 events per request. Keeping each request to at most 20
    /// scopes also bounds request/response dictionaries and durable-inbox memory on large users.
    private func startSyncPages(cursors: [String: ScopeSyncCursorPayload]) {
        let sortedCids = cursors.keys.sorted()
        var batches: [[String: ScopeSyncCursorPayload]] = []
        for startIndex in stride(from: 0, to: sortedCids.count, by: 20) {
            let endIndex = min(startIndex + 20, sortedCids.count)
            var batch: [String: ScopeSyncCursorPayload] = [:]
            for cid in sortedCids[startIndex..<endIndex] {
                batch[cid] = cursors[cid]
            }
            batches.append(batch)
        }
        guard let first = batches.first else {
            finishSync()
            return
        }
        syncLock.lock()
        pendingInitialSyncCursorBatches = Array(batches.dropFirst())
        syncLock.unlock()
        syncPage(cursors: first)
    }

    private func syncNextInitialBatchOrFinish() {
        syncLock.lock()
        let next = pendingInitialSyncCursorBatches.isEmpty
            ? nil
            : pendingInitialSyncCursorBatches.removeFirst()
        syncLock.unlock()
        if let next {
            syncPage(cursors: next)
        } else {
            finishSync()
        }
    }

    private func syncPage(cursors: [String: ScopeSyncCursorPayload]) {
        let body = E2eSyncRequestBody(cursors: cursors, removedCursor: loadRemovedSyncCursor())
        apiClient.request(endpoint: .e2eSync(body: body)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                log.error(
                    "[E2eSync] state=request_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
                self.finishSync()
            case .success(let payload):
                guard let accountId = self.mlsClient.userId else {
                    log.error("[E2eSync] Discarding response without an active account", subsystems: .mls)
                    self.finishSync()
                    return
                }
                var nextCursors: [String: ScopeSyncCursorPayload] = [:]
                var failedScopes: Set<String> = []

                for (cidString, channelPayload) in payload.channels {
                    guard let cid = try? ChannelId(cid: cidString) else {
                        failedScopes.insert(cidString)
                        log.error("[E2eSync] state=invalid_scope_cid", subsystems: .mls)
                        continue
                    }

                    do {
                        let persisted = try self.durableInboxStore.persistPage(
                            accountId: accountId,
                            scopeCid: cidString,
                            events: channelPayload.events,
                            hasMore: channelPayload.hasMore,
                            nextCursor: channelPayload.nextCursor
                        )
                        self.emitDurableInboxTelemetry(persisted.backlog)
                        if let fetchCursor = persisted.fetchCursor {
                            nextCursors[cidString] = fetchCursor
                            // Rollback-only mirror for versions predating the durable store.
                            self.saveSyncCursors([cidString: fetchCursor])
                        }
                        self.processE2eSyncEvents(
                            persisted.insertedEvents,
                            cid: cid,
                            cidString: cidString
                        )
                    } catch {
                        failedScopes.insert(cidString)
                        let repairCategory: String
                        switch error as? E2eeDurableInboxError {
                        case .backlogLimitExceeded(let scopeCid, let scopePending, let accountPending):
                            repairCategory = "durable_backlog_limit"
                            log.error(
                                "[E2eTelemetry] durable_inbox_backlog_rejected scope_pending=\(scopePending) account_pending=\(accountPending)",
                                subsystems: .mls
                            )
                        case .pageTooLarge(let scopeCid, let rawBytes, let maximumRawBytes):
                            repairCategory = "durable_page_too_large"
                            log.error(
                                "[E2eTelemetry] durable_inbox_page_rejected page_raw_bytes=\(rawBytes) maximum_raw_bytes=\(maximumRawBytes)",
                                subsystems: .mls
                            )
                        default:
                            repairCategory = "page_persistence_failed"
                        }
                        do {
                            try self.durableInboxStore.recordRepairIssue(
                                accountId: accountId,
                                scopeCid: cidString,
                                eventId: nil,
                                category: repairCategory,
                                details: String(describing: error)
                            )
                        } catch {
                            log.error(
                                "[E2eSync] state=page_repair_persist_failed "
                                    + PrivacySafeLogMetadata.errorFields(error),
                                subsystems: .mls
                            )
                        }
                        log.error(
                            "[E2eSync] state=page_persist_failed \(PrivacySafeLogMetadata.errorFields(error))",
                            subsystems: .mls
                        )
                    }
                }

                // Removal cleanup is asynchronous because it joins the same per-group MLS
                // executor as protocol/application events. Do not paginate or finish this sync
                // until every group deletion, Core Data cleanup, and removed cursor write has
                // completed.
                self.handleRemovedChannels(payload.removedChannels) { result in
                    switch result {
                    case .failure(let error):
                        log.error(
                            "[E2eSync] state=removed_cleanup_blocked "
                                + PrivacySafeLogMetadata.errorFields(error),
                            subsystems: .mls
                        )
                        self.finishSync()
                    case .success(let removedHasMore):
                        var remaining: [String: ScopeSyncCursorPayload] = [:]
                        for (cid, ch) in payload.channels where ch.hasMore && !failedScopes.contains(cid) {
                            if let next = nextCursors[cid] {
                                remaining[cid] = next
                            }
                        }
                        if !remaining.isEmpty || removedHasMore {
                            log.debug("[E2eSync] Paginating for \(remaining.count) scope(s)\(removedHasMore ? " + removed_channels" : "")", subsystems: .mls)
                            self.syncPage(cursors: remaining)
                        } else {
                            self.syncNextInitialBatchOrFinish()
                        }
                    }
                }
            }
        }
    }

    /// Emits count-only E2EE backlog observations through the SDK logger. Host apps can route
    /// the existing logger destination into their telemetry backend. No event body, plaintext,
    /// ciphertext, key, user ID, or grant URL is included.
    private func emitDurableInboxTelemetry(_ snapshot: E2eeDurableInboxStore.BacklogSnapshot) {
        guard snapshot.warningThresholdExceeded else { return }
        log.warning(
            "[E2eTelemetry] durable_inbox_backlog_warning scope_pending=\(snapshot.scopePendingCount) account_pending=\(snapshot.accountPendingCount) inserted=\(snapshot.insertedEventCount) page_raw_bytes=\(snapshot.pageRawBytes)",
            subsystems: .mls
        )
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
    /// Completion succeeds with `true` when more removal pages remain. On any failure the cursor
    /// stays unchanged and sync stops, so the same page is replayed on the next attempt.
    private func handleRemovedChannels(
        _ removed: RemovedChannelsPayload?,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard let removed else {
            completion(.success(false))
            return
        }
        guard let accountId = mlsClient.userId else {
            completion(.failure(E2eeSyncApplyError.missingAccount))
            return
        }
        guard let nextCursor = removed.nextCursor else {
            if removed.events.isEmpty && !removed.hasMore {
                completion(.success(false))
            } else {
                completion(.failure(E2eeDurableInboxError.invalidRemovedPagination))
            }
            return
        }

        let scopeCids = Set(removed.events.map(\.cid))
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            do {
                var channelCids: Set<ChannelId> = []
                var cleanedScopeCids: Set<String> = []

                for event in removed.events {
                    let cidString = event.cid
                    guard let cid = try? ChannelId(cid: cidString) else {
                        throw E2eeSyncApplyError.unsupportedEvent(type: "invalid removed cid: \(cidString)")
                    }

                    // A stale tombstone still contributes to the user-scoped cursor but must not
                    // delete state created by a later rejoin.
                    if self.isRemovalStale(
                        cidString: cidString,
                        removedAt: event.removedAt,
                        removalType: event.removalType
                    ) {
                        log.debug(
                            "[E2eSync] state=removal_skipped reason=rejoined removal_type=\(event.removalType ?? "unknown")",
                            subsystems: .mls
                        )
                        continue
                    }

                    log.debug(
                        "[E2eSync] state=removed_cleanup_started removal_type=\(event.removalType ?? "unknown")",
                        subsystems: .mls
                    )
                    if self.mlsClient.isGroupLoaded(cid: cidString) {
                        try self.performMlsMutation(cidString: cidString) {
                            try self.mlsClient.deleteGroup(cid: cidString)
                        }
                    }
                    channelCids.insert(cid)
                    cleanedScopeCids.insert(cidString)
                }

                // Core Data cleanup and removed-cursor advancement are atomic. If this throws,
                // already-deleted MLS groups remain safe because deletion is idempotent and the
                // unchanged server cursor will replay this page.
                try self.durableInboxStore.commitRemovedPage(
                    accountId: accountId,
                    channelCids: channelCids,
                    scopeCids: cleanedScopeCids,
                    nextCursor: nextCursor
                )

                self.durableApplyLock.lock()
                self.blockedDurableScopes.subtract(cleanedScopeCids)
                self.durableApplyLock.unlock()

                // Rollback-only mirrors for app versions predating the durable checkpoint.
                for cidString in cleanedScopeCids {
                    self.advanceE2eSyncCursor(for: cidString)
                }
                self.saveRemovedSyncCursor(nextCursor)
                completion(.success(removed.hasMore))
            } catch {
                do {
                    try self.durableInboxStore.recordRepairIssue(
                        accountId: accountId,
                        scopeCid: E2eeSyncCheckpointDTO.removedScope,
                        eventId: removed.events.first?.eventId,
                        category: "removed_cleanup_failed",
                        details: String(describing: error)
                    )
                } catch {
                    log.error(
                        "[E2eSync] state=removed_cleanup_repair_persist_failed "
                            + PrivacySafeLogMetadata.errorFields(error),
                        subsystems: .mls
                    )
                }
                completion(.failure(error))
            }
        }
        operation.queuePriority = Operation.QueuePriority.low
        enqueueGroupOperation(operation, cidStrings: scopeCids)
    }

    /// Marks the current sync operation as finished so a new one can start, then drains any
    /// per-channel syncs that were requested while this one was running.
    private func finishSync() {
        syncLock.lock()
        let cids = activeSyncCids
        syncLock.unlock()

        guard !cids.isEmpty else {
            completeSyncRun()
            return
        }

        // API pagination is complete, but MLS/Core Data apply operations are asynchronous.
        // The barrier makes pre/post-join completion observe fully persisted state.
        let barrier = BlockOperation { [weak self] in
            self?.completeSyncRun()
        }
        barrier.queuePriority = .low
        enqueueGroupOperation(barrier, cidStrings: cids)
    }

    private func completeSyncRun() {
        syncLock.lock()
        isSyncing = false
        activeSyncCids.removeAll()
        let completions = activeSyncCompletions
        activeSyncCompletions.removeAll()
        pendingInitialSyncCursorBatches.removeAll()
        let pending = pendingChannelSyncCids
        pendingChannelSyncCids.removeAll()
        let pendingCompletions = pendingSyncCompletions
        pendingSyncCompletions.removeAll()
        syncLock.unlock()

        completions.forEach { $0() }

        guard !pending.isEmpty else { return }
        log.debug("[E2eSync] Draining \(pending.count) queued channel sync(s)", subsystems: .mls)
        runSync(forCidStrings: pending, completion: {
            pendingCompletions.forEach { $0() }
        })
    }

    private func abortSync() {
        syncLock.lock()
        isSyncing = false
        activeSyncCids.removeAll()
        activeSyncCompletions.removeAll()
        pendingInitialSyncCursorBatches.removeAll()
        pendingChannelSyncCids.removeAll()
        pendingSyncCompletions.removeAll()
        syncLock.unlock()
    }
    
    /// Enqueues each event for one channel onto `MlsMutationExecutor` as its own
    /// low-priority operation, in server order.
    ///
    /// Splitting per event (rather than processing the whole channel in one operation) keeps
    /// the queue responsive while a sync is in flight: a high-priority foreground decrypt or a
    /// send only has to wait for the single event currently executing — not the entire
    /// channel's backlog. Per-channel ordering (protocol messages before the application
    /// messages that depend on them) is preserved by chaining each event to the previous one
    /// for the same channel via an operation dependency.
    private func processE2eSyncEvents(_ events: [E2eSyncEventEnvelope], cid: ChannelId, cidString: String) {
        // Events are already persisted by `persistPage`. Never enqueue that page directly: an
        // older durable prefix may exist after a crash or a WebSocket race. The scheduler always
        // reloads and drains the canonical durable prefix, bounded to 100 envelopes.
        scheduleDurableDrain(cid: cid, cidString: cidString)
    }

    private func scheduleDurableDrain(
        cid: ChannelId,
        cidString: String,
        resetProtocolBlock: Bool = false
    ) {
        guard let accountId = mlsClient.userId else { return }
        durableApplyLock.lock()
        if resetProtocolBlock { blockedDurableScopes.remove(cidString) }
        guard scheduledDurableDrains.insert("\(accountId)|\(cidString)").inserted else {
            durableApplyLock.unlock()
            return
        }
        durableApplyLock.unlock()

        let op = BlockOperation { [weak self] in
            guard let self else { return }
            var scheduleNext = false
            defer {
                self.durableApplyLock.lock()
                self.scheduledDurableDrains.remove("\(accountId)|\(cidString)")
                self.durableApplyLock.unlock()
                if scheduleNext {
                    self.scheduleDurableDrain(cid: cid, cidString: cidString)
                }
            }
            self.durableApplyLock.lock()
            let blocked = self.blockedDurableScopes.contains(cidString)
            self.durableApplyLock.unlock()
            guard !blocked else { return }
            do {
                let events = try self.durableInboxStore.loadPendingPrefix(
                    accountId: accountId,
                    scopeCid: cidString,
                    limit: 100
                )
                guard !events.isEmpty else { return }
                var appliedCount = 0
                for event in events {
                    if self.applyDurableEvent(event, accountId: accountId, cid: cid, cidString: cidString) {
                        appliedCount += 1
                    } else {
                        break
                    }
                }
                scheduleNext = appliedCount == events.count
            } catch {
                scheduleNext = false
                self.blockDurableScope(cidString, eventId: nil, error: error)
            }
        }
        op.queuePriority = .low
        enqueueGroupOperation(op, cidString: mlsGroupCid(for: cid).rawValue)
    }

    /// Returns false only for a protocol-prefix blocker. Metadata and application repairs keep
    /// the exact cursor moving after their repair row is durable; they never change send safety.
    private func applyDurableEvent(
        _ event: E2eSyncEventEnvelope,
        accountId: String,
        cid: ChannelId,
        cidString: String
    ) -> Bool {
        do {
            let disposition = try processSingleE2eSyncEvent(
                event,
                accountId: accountId,
                cid: cid,
                cidString: cidString
            )
            switch disposition {
            case .application(.decrypted):
                try durableInboxStore.markApplicationPersistenceCompleted(
                    accountId: accountId, scopeCid: cidString, eventId: event.eventId
                )
                try durableInboxStore.markApplicationDispositionAndApplied(
                    accountId: accountId, scopeCid: cidString, envelope: event, disposition: .decrypted
                )
                log.info("[MLS] application_checkpoint stage=scope_cursor_saved result=committed", subsystems: .mls)
            case .application(let applicationDisposition):
                try durableInboxStore.markApplicationDispositionAndApplied(
                    accountId: accountId, scopeCid: cidString, envelope: event, disposition: applicationDisposition
                )
            case .requiresCursorAdvance:
                try durableInboxStore.markApplied(accountId: accountId, scopeCid: cidString, envelope: event)
            case .cursorAdvancedAtomically:
                break
            case let .finalizeExternalJoin(commitHash, epoch, deviceId, requireReceipt):
                let trace = E2eeJoinTrace.Context(cid: cidString)
                trace.info(
                    stage: "external_commit_finalizing",
                    source: "scope_sync",
                    protocolType: MLSProtocolType.externalCommit.rawValue,
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: mlsClient.isGroupLoaded(cid: cidString),
                    localEpoch: epoch
                )
                try durableInboxStore.finalizeExternalJoinCommit(
                    accountId: accountId,
                    scopeCid: cidString,
                    envelope: event,
                    commitHash: commitHash,
                    epoch: epoch,
                    deviceId: deviceId,
                    requireReceipt: requireReceipt
                )
                normalizeHistoricalApplications(cid: cid)
                retryPendingGroupApplications(in: cid)
                trace.info(
                    stage: "external_commit_finalized",
                    source: "scope_sync",
                    protocolType: MLSProtocolType.externalCommit.rawValue,
                    result: "receipt_and_boundary_persisted",
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: mlsClient.isGroupLoaded(cid: cidString),
                    localEpoch: epoch
                )
            }
            return true
        } catch {
            let category = (error as? E2eeSyncApplyError)?.repairCategory ?? "apply_failed"
            try? durableInboxStore.recordRepairIssue(
                accountId: accountId,
                scopeCid: cidString,
                eventId: event.eventId,
                category: isKnownNonCryptoMetadata(event) ? "metadata_\(category)" : category,
                details: String(describing: error)
            )
            if isNonBlockingEvent(event) {
                do {
                    try durableInboxStore.markApplied(
                        accountId: accountId,
                        scopeCid: cidString,
                        envelope: event,
                        preservingFailure: true
                    )
                    log.debug(
                        "[E2ESyncHealth] sync_health=repairing category=\(category)",
                        subsystems: .mls
                    )
                    return true
                } catch {
                    self.blockDurableScope(cidString, eventId: event.eventId, error: error)
                    return false
                }
            }
            blockDurableScope(cidString, eventId: event.eventId, error: error)
            return false
        }
    }

    private func isKnownNonCryptoMetadata(_ event: E2eSyncEventEnvelope) -> Bool {
        switch event.event {
        case .reaction, .messageDeleted, .messageUpdated, .messagePin:
            return true
        case .unknown(let type, _):
            return ["reaction", "message_deleted", "message_updated", "message_pin"].contains(type)
        default:
            return false
        }
    }

    private func isNonBlockingEvent(_ event: E2eSyncEventEnvelope) -> Bool {
        if isKnownNonCryptoMetadata(event) { return true }
        if case .application(let application) = event.event { return !application.isSystemMessage }
        return false
    }

    private func blockDurableScope(_ cidString: String, eventId: String?, error: Error) {
        durableApplyLock.lock()
        blockedDurableScopes.insert(cidString)
        durableApplyLock.unlock()
        log.error(
            "[E2ESyncHealth] sync_health=protocol_blocked has_event=\(eventId != nil) "
                + PrivacySafeLogMetadata.errorFields(error),
            subsystems: .mls
        )
    }

    private func isPreJoinHistorical(
        _ envelope: E2eSyncEventEnvelope,
        firstDecryptableEpoch: Int64
    ) -> Bool {
        guard case .application(let application) = envelope.event,
              !application.isSystemMessage,
              let messageEpoch = application.mlsEpoch else { return false }
        return messageEpoch < firstDecryptableEpoch
    }

    private func enqueuePreJoinHistoricalRun(
        _ events: [E2eSyncEventEnvelope],
        accountId: String,
        cidString: String
    ) {
        var claimedEvents: [E2eSyncEventEnvelope] = []
        var eventKeys: [String] = []
        durableApplyLock.lock()
        for event in events {
            let eventKey = "\(accountId)|\(cidString)|\(event.eventId)"
            if enqueuedDurableEvents.insert(eventKey).inserted {
                claimedEvents.append(event)
                eventKeys.append(eventKey)
            }
        }
        durableApplyLock.unlock()
        guard !claimedEvents.isEmpty else { return }

        let op = BlockOperation { [weak self] in
            guard let self else { return }
            defer {
                self.durableApplyLock.lock()
                eventKeys.forEach { self.enqueuedDurableEvents.remove($0) }
                self.durableApplyLock.unlock()
            }
            self.durableApplyLock.lock()
            let isBlocked = self.blockedDurableScopes.contains(cidString)
            self.durableApplyLock.unlock()
            guard !isBlocked else { return }

            do {
                try self.durableInboxStore.markApplicationDispositionsAndApplied(
                    accountId: accountId,
                    scopeCid: cidString,
                    applications: claimedEvents.map { ($0, .preJoinHistorical) }
                )
            } catch {
                try? self.durableInboxStore.recordRepairIssue(
                    accountId: accountId,
                    scopeCid: cidString,
                    eventId: claimedEvents.first?.eventId,
                    category: "historical_batch_apply_failed",
                    details: String(describing: error)
                )
                self.durableApplyLock.lock()
                self.blockedDurableScopes.insert(cidString)
                self.durableApplyLock.unlock()
                log.error(
                    "[E2eSync] state=historical_batch_persist_failed action=scope_blocked "
                        + PrivacySafeLogMetadata.errorFields(error),
                    subsystems: .mls
                )
            }
        }
        op.queuePriority = .low
        enqueueGroupOperation(op, cidString: cidString)
    }

    private func enqueueE2eSyncEventsIndividually(
        _ events: [E2eSyncEventEnvelope],
        cid: ChannelId,
        cidString: String
    ) {
        guard let accountId = mlsClient.userId else {
            log.error("[E2eSync] Cannot enqueue durable events without an active account", subsystems: .mls)
            return
        }
        for event in events {
            let eventKey = "\(accountId)|\(cidString)|\(event.eventId)"
            durableApplyLock.lock()
            let isNewlyEnqueued = enqueuedDurableEvents.insert(eventKey).inserted
            durableApplyLock.unlock()
            guard isNewlyEnqueued else { continue }

            let op = BlockOperation { [weak self] in
                guard let self else { return }
                defer {
                    self.durableApplyLock.lock()
                    self.enqueuedDurableEvents.remove(eventKey)
                    self.durableApplyLock.unlock()
                }

                self.durableApplyLock.lock()
                let isBlocked = self.blockedDurableScopes.contains(cidString)
                self.durableApplyLock.unlock()
                guard !isBlocked else { return }

                do {
                    let disposition = try self.processSingleE2eSyncEvent(
                        event,
                        accountId: accountId,
                        cid: cid,
                        cidString: cidString
                    )
                    if case .application(.decrypted) = disposition {
                        try self.durableInboxStore.markApplicationPersistenceCompleted(
                            accountId: accountId,
                            scopeCid: cidString,
                            eventId: event.eventId
                        )
                    }
                    if case .application(let applicationDisposition) = disposition {
                        try self.durableInboxStore.markApplicationDispositionAndApplied(
                            accountId: accountId,
                            scopeCid: cidString,
                            envelope: event,
                            disposition: applicationDisposition
                        )
                    } else if case .requiresCursorAdvance = disposition {
                        try self.durableInboxStore.markApplied(
                            accountId: accountId,
                            scopeCid: cidString,
                            envelope: event
                        )
                        if case .protocol(let protocolData) = event.event,
                           protocolData.type == .externalCommit,
                           let commit = protocolData.commit,
                           let deviceId = protocolData.deviceId {
                            try self.durableInboxStore.finalizeLocalJoinReceipt(
                                accountId: accountId,
                                scopeCid: cidString,
                                commitHash: Data(SHA256.hash(data: Data(commit))),
                                epoch: UInt64(protocolData.epoch),
                                deviceId: deviceId
                            )
                        }
                    }
                } catch {
                    let category = (error as? E2eeSyncApplyError)?.repairCategory ?? "apply_failed"
                    do {
                        try self.durableInboxStore.recordRepairIssue(
                            accountId: accountId,
                            scopeCid: cidString,
                            eventId: event.eventId,
                            category: category,
                            details: String(describing: error)
                        )
                    } catch {
                        log.error(
                            "[E2eSync] state=repair_issue_persist_failed "
                                + PrivacySafeLogMetadata.errorFields(error),
                            subsystems: .mls
                        )
                        // Without a durable repair record, advancing even an application event
                        // would erase the only actionable failure state. Keep the scope blocked
                        // and leave the exact raw inbox event unapplied for the next replay.
                        self.durableApplyLock.lock()
                        self.blockedDurableScopes.insert(cidString)
                        self.durableApplyLock.unlock()
                        log.error(
                            "[E2eSync] state=apply_blocked reason=repair_persistence_failed",
                            subsystems: .mls
                        )
                        return
                    }

                    // An application ciphertext is already durable in the inbox. Bellboy's
                    // recovery contract allows its cursor to advance after recording a repair
                    // issue, so one unreadable historical message cannot prevent later commits
                    // from advancing the group or block every new outgoing send. The raw event
                    // remains available by event ID for manual/PIN recovery and the UI keeps its
                    // encrypted placeholder. Protocol failures remain scope-blocking because
                    // skipping a commit would make every following epoch unsafe.
                    if case .application(let application) = event.event,
                       !application.isSystemMessage {
                        do {
                            try self.durableInboxStore.markApplied(
                                accountId: accountId,
                                scopeCid: cidString,
                                envelope: event,
                                preservingFailure: true
                            )
                            log.error(
                                "[E2eSync] state=application_repair_persisted action=continue "
                                    + PrivacySafeLogMetadata.errorFields(error),
                                subsystems: .mls
                            )
                            return
                        } catch {
                            log.error(
                                "[E2eSync] state=repaired_application_advance_failed "
                                    + PrivacySafeLogMetadata.errorFields(error),
                                subsystems: .mls
                            )
                        }
                    }

                    self.durableApplyLock.lock()
                    self.blockedDurableScopes.insert(cidString)
                    self.durableApplyLock.unlock()
                    log.error(
                        "[E2eSync] state=apply_blocked has_event=true "
                            + PrivacySafeLogMetadata.errorFields(error),
                        subsystems: .mls
                    )
                }
            }
            op.queuePriority = .low
            enqueueGroupOperation(op, cidString: cidString)
        }
    }

    /// Replays locally durable, unapplied events before newly fetched pages are enqueued.
    /// Starting a new sync run clears the in-memory block so the first failed event can retry;
    /// if the root cause is still present it immediately records the failure and blocks again.
    private func replayDurablePendingEvents(scopeCids: Set<String>) {
        for cidString in scopeCids {
            guard let cid = try? ChannelId(cid: cidString) else { continue }
            scheduleDurableDrain(cid: cid, cidString: cidString, resetProtocolBlock: true)
        }
    }

    /// Applies a single E2EE sync event. Must run on `MlsMutationExecutor`.
    private func processSingleE2eSyncEvent(
        _ envelope: E2eSyncEventEnvelope,
        accountId: String,
        cid: ChannelId,
        cidString: String
    ) throws -> E2eeSyncApplyDisposition {
        switch envelope.event {
        case .protocol(let data):
            return try applyE2eSyncProtocolEvent(
                data,
                accountId: accountId,
                eventId: envelope.eventId,
                envelope: envelope,
                cidString: cidString
            )
        case .application(let data):
            if data.isSystemMessage {
                handleSystemMessage(data, cid: cid)
            } else {
                let effectiveCid = mlsGroupCid(for: cid)
                let localGeneration = Int(
                    mlsClient.loadGenerationMarker(cid: effectiveCid.rawValue)?.generation ?? 0
                )
                if data.groupGeneration < localGeneration {
                    return .application(.preJoinHistorical)
                }
                if data.groupGeneration > localGeneration {
                    enqueueBootstrap(for: effectiveCid)
                    return .application(.pendingGroup)
                }
                let firstDecryptableEpoch = firstDecryptableEpoch(for: effectiveCid)
                let joinBoundary = try durableInboxStore.localJoinBoundary(
                    accountId: accountId,
                    scopeCid: cidString
                )
                let awaitingBoundary = try durableInboxStore.localJoinReceiptProof(
                    accountId: accountId,
                    scopeCid: cidString
                )?.status == .merged && joinBoundary == nil
                let groupLoaded = mlsClient.isGroupLoaded(cid: effectiveCid.rawValue)
                let action = E2eeApplicationEpochAction.resolve(
                    envelope: envelope,
                    messageEpoch: data.mlsEpoch,
                    firstDecryptableEpoch: firstDecryptableEpoch,
                    joinBoundary: joinBoundary,
                    awaitingExternalCommitBoundary: awaitingBoundary,
                    hasGroup: groupLoaded
                )
                let actionName: String
                switch action {
                case .preJoinHistorical: actionName = "pre_join_historical"
                case .pendingGroup: actionName = "pending_group"
                case .decrypt: actionName = "decrypt"
                }
                E2eeJoinTrace.Context(cid: cidString).info(
                    stage: "application_epoch_classified",
                    source: "scope_sync",
                    result: actionName,
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: groupLoaded,
                    eventEpoch: data.mlsEpoch.map(Int.init),
                    firstDecryptableEpoch: firstDecryptableEpoch
                )
                switch action {
                case .preJoinHistorical:
                    return .application(.preJoinHistorical)
                case .pendingGroup:
                    return .application(.pendingGroup)
                case .decrypt:
                    break
                }
                // Call the synchronous body directly — we are already on the mutation executor,
                // so we must NOT re-enqueue via decryptMessagePayload (that would deadlock
                // the serial queue waiting on itself).
                guard let mlsCiphertext = data.mlsCiphertext else {
                    throw E2eeSyncApplyError.missingCiphertext(messageId: data.id)
                }
                if let cached = durableOwnPlaintext(
                    messageId: data.id,
                    ciphertext: Data(mlsCiphertext),
                    cid: cid
                ) {
                    e2eeAttachmentReceiveCoordinator.hydratePreviews(
                        payload: cached,
                        messageId: data.id,
                        cid: cid,
                        source: .scopeSync
                    )
                    return .application(.decrypted)
                }
                _ = try decryptMessagePayloadSyncThrowing(
                    messageId: data.id,
                    encryptedData: Data(mlsCiphertext),
                    cid: cid,
                    receiveSource: .scopeSync,
                    expectedEnvelope: data.e2eeReceivedEnvelope
                )
                return .application(.decrypted)
            }
        case .reaction(let data):
            try handleReactionSyncEvent(data)
        case .messageDeleted(let data):
            try handleMessageDeletedSyncEvent(data)
        case .messageUpdated(let data):
            try handleMessageUpdatedSyncEvent(data, cid: cid)
        case .messagePin(let data):
            try handleMessagePinSyncEvent(data, cid: cid)
        case .memberRemoved(let data, _):
            try handleMemberRemovedSyncEvent(data, cid: cid)
        case .inviteAccepted(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid, accepted: true)
        case .inviteRejected(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .inviteMessagingRejected(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .inviteMessagingSkipped(let data, _):
            handleInviteRespondSyncEvent(data, cid: cid)
        case .websocketEvent(let payload):
            try handleWebsocketEvent(payload)
        case .unknown(let type, _):
            throw E2eeSyncApplyError.unsupportedEvent(type: type)
        }
        return .requiresCursorAdvance
    }

    private func firstDecryptableEpoch(for cid: ChannelId) -> Int64? {
        var epoch: Int64?
        database.viewContext.performAndWait {
            epoch = ChannelDTO.load(cid: cid, context: database.viewContext)?
                .mlsFirstDecryptableEpoch?.int64Value
        }
        return epoch
    }

    private func normalizeHistoricalApplicationsAndWait(cid: ChannelId) throws {
        guard let accountId = mlsClient.userId,
              let firstEpoch = firstDecryptableEpoch(for: mlsGroupCid(for: cid)) else { return }
        let boundary = try durableInboxStore.localJoinBoundary(
            accountId: accountId,
            scopeCid: cid.rawValue
        )
        try durableInboxStore.normalizePreJoinHistoricalApplications(
            accountId: accountId,
            scopeCid: cid.rawValue,
            firstDecryptableEpoch: firstEpoch,
            joinBoundary: boundary
        )
    }

    private func normalizeHistoricalApplications(cid: ChannelId) {
        do {
            try normalizeHistoricalApplicationsAndWait(cid: cid)
        } catch {
            log.error(
                "[E2eSync] state=historical_application_normalize_failed",
                subsystems: .mls
            )
        }
    }

    private func durableOwnPlaintext(
        messageId: MessageId,
        ciphertext: Data,
        cid: ChannelId
    ) -> E2ePayload? {
        var payload: E2ePayload?
        e2eReadContext.performAndWait {
            guard let message = MessageDTO.load(id: messageId, context: e2eReadContext),
                  message.cid == cid.rawValue,
                  message.encryptedData == ciphertext,
                  let decrypted = message.decryptedMessage else { return }
            payload = try? decrypted.asPayload()
        }
        return payload
    }

    private func hydrateDurablePayloadIfPresent(
        messageId: MessageId,
        cid: ChannelId,
        source: E2eeAttachmentReceiveSource
    ) {
        var payload: E2ePayload?
        e2eReadContext.performAndWait {
            payload = MessageDecryptDTO.load(messageId: messageId, context: e2eReadContext)
                .flatMap { try? $0.asPayload() }
        }
        guard let payload else { return }
        e2eeAttachmentReceiveCoordinator.hydratePreviews(
            payload: payload,
            messageId: messageId,
            cid: cid,
            source: source
        )
    }

    /// Restores process-local E2EE preview bytes for messages materialized by a channel query.
    ///
    /// Decrypted preview bytes intentionally live only in `E2eeAttachmentPreviewCache`, so they
    /// disappear after every relaunch. A scope sync with no new application events cannot restore
    /// that cache by itself. Channel queries, however, materialize the visible message page on
    /// every open/reload; use that boundary to rehydrate only the previews in that page from the
    /// durable authenticated manifests. Original assets remain explicit user-initiated downloads.
    func hydrateCachedAttachmentPreviews(messageIds: [MessageId], cid: ChannelId) {
        guard !messageIds.isEmpty else { return }
        let uniqueMessageIds = Array(Set(messageIds))
        e2eReadContext.perform { [weak self] in
            guard let self else { return }
            for messageId in uniqueMessageIds {
                guard let payload = MessageDecryptDTO.load(messageId: messageId, context: self.e2eReadContext)
                    .flatMap({ try? $0.asPayload() }),
                    !payload.e2eeAttachments.isEmpty else { continue }
                self.e2eeAttachmentReceiveCoordinator.hydratePreviews(
                    payload: payload,
                    messageId: messageId,
                    cid: cid,
                    source: .cachedModel
                )
            }
        }
    }

    /// Loads the authenticated preview for one Channel Info projection item.
    ///
    /// The public item intentionally does not expose its manifest or key material. Resolve those
    /// bytes again from the durable decrypted-message cache, then join the same bounded preview
    /// flight used by websocket/scope-sync hydration. A manifest without a preview is a valid
    /// original-only attachment and returns `nil`; it must never trigger an original download.
    func loadChannelInfoAttachmentPreview(
        for item: E2eeChannelAttachmentListItem
    ) async throws -> Data? {
#if canImport(UIKit)
        let protectedDataAvailable = await MainActor.run {
            UIApplication.shared.isProtectedDataAvailable
        }
        try E2eeChannelAttachmentPreviewAccessGate.requireProtectedData(
            isAvailable: protectedDataAvailable
        )
#endif
        let messageId = item.messageId
        let attachmentId = item.attachmentId
        let cid = item.cid
        let manifest: E2eeAttachmentManifestV1 = try await withCheckedThrowingContinuation { continuation in
            e2eReadContext.perform { [e2eReadContext] in
                do {
                    guard let payload = try MessageDecryptDTO.load(
                        messageId: messageId,
                        context: e2eReadContext
                    ).flatMap({ try $0.asPayload() }),
                    let manifest = payload.e2eeAttachments.first(where: {
                        $0.attachmentId == attachmentId
                    }) else {
                        throw E2eeChannelAttachmentProjectionError.missingManifest
                    }
                    try manifest.validate()
                    continuation.resume(returning: manifest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        return try await e2eeAttachmentReceiveCoordinator.loadPreview(
            manifest: manifest,
            cid: cid,
            source: .channelInfo
        )
    }

    private func retryPendingGroupApplications(in cid: ChannelId) {
        guard let accountId = mlsClient.userId else { return }
        let scopeCid = cid.rawValue
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            do {
                let events = try self.durableInboxStore.loadApplicationEvents(
                    accountId: accountId,
                    scopeCid: scopeCid,
                    disposition: .pendingGroup
                )
                let firstEpoch = self.firstDecryptableEpoch(for: self.mlsGroupCid(for: cid))
                let boundary = try self.durableInboxStore.localJoinBoundary(
                    accountId: accountId,
                    scopeCid: scopeCid
                )
                let awaitingBoundary = try self.durableInboxStore.localJoinReceiptProof(
                    accountId: accountId,
                    scopeCid: scopeCid
                )?.status == .merged && boundary == nil
                for envelope in events {
                    do {
                        guard case .application(let application) = envelope.event else { continue }
                        let action = E2eeApplicationEpochAction.resolve(
                            envelope: envelope,
                            messageEpoch: application.mlsEpoch,
                            firstDecryptableEpoch: firstEpoch,
                            joinBoundary: boundary,
                            awaitingExternalCommitBoundary: awaitingBoundary,
                            hasGroup: self.mlsClient.isGroupLoaded(cid: self.mlsGroupCid(for: cid).rawValue)
                        )
                        if action == .preJoinHistorical {
                            try self.durableInboxStore.updateAppliedApplicationDisposition(
                                accountId: accountId,
                                scopeCid: scopeCid,
                                eventId: envelope.eventId,
                                disposition: .preJoinHistorical
                            )
                            continue
                        }
                        guard action == .decrypt else { continue }
                        guard let ciphertext = application.mlsCiphertext else { continue }
                        if let cached = self.durableOwnPlaintext(
                            messageId: application.id,
                            ciphertext: Data(ciphertext),
                            cid: cid
                        ) {
                            self.e2eeAttachmentReceiveCoordinator.hydratePreviews(
                                payload: cached,
                                messageId: application.id,
                                cid: cid,
                                source: .scopeSync
                            )
                            try self.durableInboxStore.markApplicationPersistenceCompleted(
                                accountId: accountId,
                                scopeCid: scopeCid,
                                eventId: envelope.eventId
                            )
                            try self.durableInboxStore.updateAppliedApplicationDisposition(
                                accountId: accountId,
                                scopeCid: scopeCid,
                                eventId: envelope.eventId,
                                disposition: .decrypted
                            )
                            continue
                        }
                        _ = try self.decryptMessagePayloadSyncThrowing(
                            messageId: application.id,
                            encryptedData: Data(ciphertext),
                            cid: cid,
                            receiveSource: .scopeSync,
                            expectedEnvelope: application.e2eeReceivedEnvelope
                        )
                        try self.durableInboxStore.markApplicationPersistenceCompleted(
                            accountId: accountId,
                            scopeCid: scopeCid,
                            eventId: envelope.eventId
                        )
                        try self.durableInboxStore.updateAppliedApplicationDisposition(
                            accountId: accountId,
                            scopeCid: scopeCid,
                            eventId: envelope.eventId,
                            disposition: .decrypted
                        )
                    } catch {
                        try? self.durableInboxStore.recordRepairIssue(
                            accountId: accountId,
                            scopeCid: scopeCid,
                            eventId: envelope.eventId,
                            category: "application_decrypt_failed",
                            details: String(describing: error)
                        )
                    }
                }
            } catch {
                log.error(
                    "[E2eSync] state=pending_group_retry_failed "
                        + PrivacySafeLogMetadata.errorFields(error),
                    subsystems: .mls
                )
            }
        }
        op.queuePriority = .low
        enqueueGroupOperation(op, cidString: mlsGroupCid(for: cid).rawValue)
    }

    /// Handles a websocket event received during E2EE sync by dispatching it
    /// through the standard event processing pipeline.
    private func handleWebsocketEvent(_ payload: EventPayload) throws {
        if payload.eventType == .memberRemoved {
            try handleMemberRemovedEvent(payload)
            return
        }
        throw E2eeSyncApplyError.unsupportedEvent(type: payload.eventType.rawValue)
    }

    /// Handles a member.removed event received during E2EE sync.
    /// Called on `MlsMutationExecutor`.
    /// - Parameter payload: The event payload for the member removal.
    private func handleMemberRemovedEvent(_ payload: EventPayload) throws {
        let event = try MemberRemovedEventDTO(from: payload)
        let targetUserId = event.member.userId
        let cidString = event.cid.rawValue

        if targetUserId == mlsClient.userId {
            if mlsClient.isGroupLoaded(cid: cidString) {
                try deleteGroup(cid: cidString)
            }
            try deleteGroups(cids: event.topicCids.map { $0.rawValue })
            log.debug("[E2E] state=local_group_deleted reason=current_user_removed", subsystems: .mls)
        } else if event.selfRemove == true {
            try database.writeAndWait { session in
                session.savePendingRemoveMember(userId: targetUserId, channelCid: cidString)
            }
            log.debug("[E2E] state=pending_eviction_saved reason=member_self_left", subsystems: .mls)

            if isDesignatedEvictor(cid: event.cid) {
                commitEviction(cid: event.cid, targetUserIds: [targetUserId])
            }
        }
    }
    
    // MARK: - Sync Event Handlers

    /// Handles a `reaction` sync event by saving/updating the reaction snapshot in the database.
    /// Called on `MlsMutationExecutor`.
    private func handleReactionSyncEvent(_ data: ReactionSyncData) throws {
        log.debug("[E2eSync] state=metadata_apply_started type=reaction", subsystems: .mls)
        try database.writeAndWait { session in
            // Save the message first so the reaction has a target
            try session.saveMessage(payload: data.message, for: data.cid, syncOwnReactions: true, cache: nil)
            // Save the reaction (creates or updates)
            try session.saveReaction(payload: data.reaction, cache: nil)
        }
    }

    /// Handles a `message_deleted` sync event by removing the message from local cache.
    /// Called on `MlsMutationExecutor`.
    private func handleMessageDeletedSyncEvent(_ data: MessageDeletedSyncData) throws {
        log.debug("[E2eSync] state=metadata_apply_started type=message_deleted", subsystems: .mls)
        try database.writeAndWait { session in
            // Save the message payload which includes deletedAt being set
            try session.saveMessage(payload: data.message, for: data.cid, syncOwnReactions: false, cache: nil)
        }
    }

    /// Handles a `message_updated` sync event by decrypting the latest snapshot and upserting it.
    /// Called on `MlsMutationExecutor`.
    private func handleMessageUpdatedSyncEvent(_ data: MessageUpdatedSyncData, cid: ChannelId) throws {
        let messageId = data.message.id
        log.debug("[E2eSync] state=metadata_apply_started type=message_updated", subsystems: .mls)

        // Check if the message has encrypted data that may need re-decryption
        if let encryptedBytes = data.message.encryptedData {
            let encryptedData = Data(encryptedBytes)
            // Save the updated message payload. Do NOT delete the decrypted cache here — a
            // `message_updated` sync event is often a non-content change (reaction/pin/read/
            // re-delivery) that carries the original, already-consumed ciphertext; re-decrypting
            // it would fail and regress the message to the "encrypted" placeholder.
            // See reDecryptUpdatedMessageSync.
            try database.writeAndWait { session in
                try session.saveMessage(payload: data.message, for: cid, syncOwnReactions: false, cache: nil)
            }
            reDecryptUpdatedMessageSync(
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                receiveSource: .scopeSync
            )
        } else {
            // No encrypted data — just save the message payload directly
            try database.writeAndWait { session in
                try session.saveMessage(payload: data.message, for: cid, syncOwnReactions: false, cache: nil)
            }
        }
    }

    /// Handles a `message_pin` sync event by patching the pin/unpin state on the message.
    /// Called on `MlsMutationExecutor`.
    private func handleMessagePinSyncEvent(_ data: MessagePinSyncData, cid: ChannelId) throws {
        log.debug("[E2eSync] state=metadata_apply_started type=message_pin", subsystems: .mls)
        try database.writeAndWait { session in
            // Save the message which includes pin fields (pinnedAt, pinnedBy, pinExpires)
            try session.saveMessage(payload: data.message, for: cid, syncOwnReactions: false, cache: nil)
        }
    }

    /// Handles a `member_removed` sync event.
    /// If `selfRemove` is true, queues a pending ghost for composite cleanup.
    /// If `selfRemove` is false, treats as admin kick.
    /// Called on `MlsMutationExecutor`.
    /// - Parameters:
    ///   - data: The member removal data (member + selfRemove flag).
    ///   - cid: The channel ID from the sync envelope.
    private func handleMemberRemovedSyncEvent(_ data: MemberRemovedSyncData, cid: ChannelId) throws {
        guard let member = data.memberContainer.member else {
            throw E2eeSyncApplyError.missingMember
        }

        let userId = member.userId
        let cidString = cid.rawValue

        if userId == mlsClient.userId {
            membershipRefresh?.invalidate(cid)
            // Current user was removed → delete local MLS group and stop E2EE for this channel.
            let trace = E2eeJoinTrace.Context(cid: cidString)
            let groupLoaded = mlsClient.isGroupLoaded(cid: cidString)
            trace.info(
                stage: "current_user_removed",
                source: "scope_sync",
                receipt: joinReceiptTraceStatus(for: cidString),
                groupLoaded: groupLoaded
            )
            if groupLoaded {
                try deleteGroup(cid: cidString)
            }
            trace.info(
                stage: "local_group_delete_finished",
                source: "scope_sync",
                result: groupLoaded ? "deleted" : "already_missing",
                receipt: joinReceiptTraceStatus(for: cidString),
                groupLoaded: mlsClient.isGroupLoaded(cid: cidString)
            )
            log.debug("[E2eSync] state=local_group_deleted reason=current_user_removed", subsystems: .mls)
        } else if data.selfRemove {
            // Another member self-removed → queue ghost cleanup.
            try database.writeAndWait { session in
                session.savePendingRemoveMember(userId: userId, channelCid: cidString)
            }
            log.debug("[E2eSync] state=pending_eviction_saved reason=member_self_left", subsystems: .mls)

            // Designated evictor performs actual MLS removal.
            if isDesignatedEvictor(cid: cid) {
                commitEviction(cid: cid, targetUserIds: [userId])
            }
        }
        // Admin kick: do nothing extra — standard remove flow includes the MLS commit.
    }

    /// Handles an invite respond-back sync event (accepted, rejected, messaging_rejected, messaging_skipped).
    /// Triggers E2E channel sync when MLS is enabled, matching the websocket event behavior.
    /// Called on `MlsMutationExecutor`.
    /// - Parameters:
    ///   - data: The invite respond data (mlsEnabled, member, topicCids).
    ///   - cid: The channel ID from the sync envelope.
    private func handleInviteRespondSyncEvent(
        _ data: InviteRespondSyncData,
        cid: ChannelId,
        accepted: Bool = false
    ) {
        guard data.mlsEnabled else { return }
        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        let bootstrapping = bootstrapQueue.deferSyncIfAdmitted(cid)
        if bootstrapping {
            trace.info(
                stage: "invite_response_received",
                source: "scope_sync",
                result: "coalesced",
                reason: "bootstrap_active",
                receipt: joinReceiptTraceStatus(for: cid.rawValue),
                groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
                deferredSync: true
            )
            log.debug("[E2eSync] state=invite_sync_coalesced reason=bootstrap", subsystems: .mls)
            return
        }
        trace.info(
            stage: "invite_response_received",
            source: "scope_sync",
            result: "scope_sync_requested",
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
            deferredSync: false
        )
        log.debug("[E2eSync] state=invite_response_processing", subsystems: .mls)
        if accepted, data.memberContainer.member?.userId == mlsClient.userId {
            reconcileAcceptedMembership(in: cid)
        } else if accepted {
            enqueueBootstrap(for: cid)
        } else {
            performE2eChannelSync(cid: cid)
        }
    }

    // MARK: - System Message Handling
    
    /// Handles a system message received during E2EE sync.
    /// Called on `MlsMutationExecutor`. System messages are plain-text and do not require MLS decryption.
    /// - Parameters:
    ///   - data: The application event data with `type == .system`.
    ///   - cid: The channel this message belongs to.
    private func handleSystemMessage(_ data: E2eSyncApplicationData, cid: ChannelId) {
        // Explicit supported no-op: Bellboy system events carry no MLS state transition and the
        // existing iOS message store has no system-message projection. Keeping this branch typed
        // allows the durable inbox to advance without treating the event as an unknown success.
        log.debug(
            "[E2E] state=system_message_received has_text=\(data.text?.isEmpty == false)",
            subsystems: .mls
        )
    }
    
    /// Synchronous decryption body. Must only be called from `MlsMutationExecutor`.
    /// External callers should use `decryptMessagePayload` which enqueues this onto the queue.
    private func decryptMessagePayloadSync(
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        receiveSource: E2eeAttachmentReceiveSource,
        expectedEnvelope: E2eeReceivedMessageEnvelope? = nil,
        completion: ((_ result: Result<E2ePayload, Error>) -> Void)? = nil
    ) {
        do {
            completion?(.success(try decryptMessagePayloadSyncThrowing(
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                receiveSource: receiveSource,
                expectedEnvelope: expectedEnvelope
            )))
        } catch {
            log.error(
                "[MLS] state=message_decrypt_failed \(PrivacySafeLogMetadata.errorFields(error))"
            )
            completion?(.failure(error))
        }
    }

    /// Same crash-safe plaintext-first flow as `decryptMessagePayloadSync`, but exposes a
    /// synchronous success boundary to the durable sync inbox.
    private func decryptMessagePayloadSyncThrowing(
        messageId: MessageId,
        encryptedData: Data,
        cid: ChannelId,
        receiveSource: E2eeAttachmentReceiveSource,
        expectedEnvelope: E2eeReceivedMessageEnvelope? = nil
    ) throws -> E2ePayload {
        // Re-check the DB cache — a prior operation may have populated it.
        // Read on the background read-only context so the decrypt hot path never
        // hops to (and blocks on) the main-queue `viewContext`, and never on
        // `backgroundReadOnlyContext` (which a synchronous send may be blocking).
        var cachedPayload: E2ePayload?
        var cachedCiphertextHash: Data?
        let readContext = e2eReadContext
        readContext.performAndWait {
            if let dto = MessageDecryptDTO.load(messageId: messageId, context: readContext) {
                cachedPayload = try? dto.asPayload()
                cachedCiphertextHash = dto.ciphertextHash
            }
        }
        
        if let cached = cachedPayload {
            // A crash can leave plaintext committed while the provider still contains the old
            // ratchet state. Replay once to finish that write; a consumed-secret error proves the
            // provider save had already completed before the crash.
            do {
                let group = try mlsClient.loadGroup(with: mlsGroupCid(for: cid).rawValue)
                let processed = try mlsClient.processApplicationMessage(data: encryptedData, in: group)
                let authenticatedPayload = try persistProcessedApplicationMessage(
                    processed,
                    messageId: messageId,
                    encryptedData: encryptedData,
                    cid: cid,
                    group: group,
                    receiveSource: receiveSource,
                    expectedEnvelope: expectedEnvelope
                )
                return authenticatedPayload
            } catch {
                guard E2eeApplicationReplayRecovery.canFinalizeFromCachedPlaintext(
                    error: error,
                    cachedCiphertextHash: cachedCiphertextHash,
                    ciphertext: encryptedData
                ) else { throw error }
                try validateCachedPayload(cached, expectedEnvelope: expectedEnvelope)
                e2eeAttachmentReceiveCoordinator.hydratePreviews(
                    payload: cached,
                    messageId: messageId,
                    cid: cid,
                    source: .replayRecovery
                )
                return cached
            }
        }
        
        // No cache — run MLS decrypt. A topic message is encrypted with its parent
        // channel's MLS group, so resolve the topic cid to the group-owning cid first.
        let group = try mlsClient.loadGroup(with: mlsGroupCid(for: cid).rawValue)
        log.debug("[MLS] Current group epoch: \(group.epoch())", subsystems: .mls)
        let processed = try mlsClient.processApplicationMessage(data: encryptedData, in: group)
        let authenticatedPayload = try persistProcessedApplicationMessage(
            processed,
            messageId: messageId,
            encryptedData: encryptedData,
            cid: cid,
            group: group,
            receiveSource: receiveSource,
            expectedEnvelope: expectedEnvelope
        )
        return authenticatedPayload
    }

    private func validateCachedPayload(
        _ payload: E2ePayload,
        expectedEnvelope: E2eeReceivedMessageEnvelope?
    ) throws {
        guard let expectedEnvelope else { return }
        guard expectedEnvelope.requiresAAD else {
            guard payload.authenticatedMetadata == nil,
                  payload.e2eeAttachments.isEmpty else {
                throw E2eeMessageAADError.authenticatedMetadataMismatch
            }
            return
        }
        guard let metadata = payload.authenticatedMetadata else {
            throw E2eeMessageAADError.authenticatedMetadataMismatch
        }
        let expectedIds = try E2eeMessageAADV1.canonicalAttachmentIds(
            expectedEnvelope.attachmentIds
        )
        guard metadata.forwardCid == expectedEnvelope.forwardCid,
              metadata.forwardMessageId == expectedEnvelope.forwardMessageId,
              metadata.forwardParentCid == expectedEnvelope.forwardParentCid,
              metadata.attachmentIds == expectedIds else {
            throw E2eeMessageAADError.authenticatedMetadataMismatch
        }
        try payload.e2eeAttachments.verifyCanonicalAttachmentIds(expectedIds)
    }

    /// Re-attempts decryption for messages in `cid` that still hold ciphertext but have
    /// no cached plaintext yet. Called after a commit/welcome advances the group epoch so
    /// messages that arrived *before* their epoch's protocol message self-heal, instead of
    /// being stuck on the "encrypted" placeholder until the user leaves and re-opens the
    /// channel. Idempotent: messages already decrypted (cache present) are skipped.
    private func reDecryptPendingMessages(in cid: ChannelId) {
        let context = e2eReadContext
        var pending: [(id: MessageId, data: Data)] = []
        let effectiveCid = mlsGroupCid(for: cid)
        let firstEpoch = firstDecryptableEpoch(for: effectiveCid)
        context.performAndWait {
            let request = NSFetchRequest<MessageDTO>(entityName: MessageDTO.entityName)
            if let firstEpoch {
                request.predicate = NSPredicate(
                    format: "cid == %@ AND encryptedData != nil AND decryptedMessage == nil AND mlsEpoch >= %lld",
                    cid.rawValue,
                    firstEpoch
                )
            } else {
                request.predicate = NSPredicate(
                    format: "cid == %@ AND encryptedData != nil AND decryptedMessage == nil",
                    cid.rawValue
                )
            }
            guard let results = try? context.fetch(request) else { return }
            pending = results.compactMap { dto in
                guard let data = dto.encryptedData else { return nil }
                return (dto.id, data)
            }
        }
        guard !pending.isEmpty else { return }
        log.debug(
            "[MLS] state=pending_redecrypt_started message_count=\(pending.count) reason=epoch_advanced",
            subsystems: .mls
        )
        for item in pending {
            decryptMessagePayload(
                messageId: item.id,
                encryptedData: item.data,
                cid: cid,
                receiveSource: .scopeSync
            )
        }
    }

    private func applyE2eSyncProtocolEvent(
        _ data: E2eSyncProtocolData,
        accountId: String,
        eventId: String,
        envelope: E2eSyncEventEnvelope,
        cidString: String
    ) throws -> E2eeSyncApplyDisposition {
        let trace = E2eeJoinTrace.Context(cid: cidString)
        let targetedAtCurrentUser = data.targetUserIds.map { targetUserIds in
            mlsClient.userId.map(targetUserIds.contains) ?? false
        }
        let localGeneration = mlsClient.loadGenerationMarker(cid: cidString)?.generation ?? 0
        let incomingGeneration = UInt64(data.groupGeneration)
        if incomingGeneration < localGeneration {
            return .requiresCursorAdvance
        }
        trace.info(
            stage: "protocol_apply_started",
            source: "scope_sync",
            protocolType: data.type.rawValue,
            receipt: joinReceiptTraceStatus(for: cidString),
            groupLoaded: mlsClient.isGroupLoaded(cid: cidString),
            targetedAtCurrentUser: targetedAtCurrentUser,
            eventEpoch: data.epoch
        )
        switch data.type {
            case .commit, .externalCommit:
                if incomingGeneration > localGeneration {
                    // This device did not install the reset Welcome. It must discover the
                    // authoritative generation and external-join; processing with the old
                    // provider would cross generation namespaces.
                    return .requiresCursorAdvance
                }
                // The rollout control is evaluated before every commit disposition. In
                // particular, a missing local group is not proof that the commit was already
                // applied and therefore must not advance the durable cursor while replay is off.
                guard mlsRolloutControls.historicalReplayEnabled else {
                    emitMlsRolloutMetric(
                        .init(
                            name: .delayedCommit,
                            outcome: .disabled,
                            reason: .historicalReplayDisabled
                        )
                    )
                    throw E2eeSyncApplyError.invalidCommit(
                        reason: "historical replay disabled by rollout control"
                    )
                }
                // A device without this group is not a recipient of historical commits. Its
                // canonical join artifact is a matching Welcome; otherwise bootstrap falls back
                // to current GroupInfo. Marking the commit safe prevents it from blocking the
                // later Welcome in the same ordered scope page.
                guard mlsClient.isGroupLoaded(cid: cidString) else {
                    trace.info(
                        stage: "commit_skipped",
                        source: "scope_sync",
                        protocolType: data.type.rawValue,
                        result: "cursor_advance",
                        reason: "group_missing",
                        receipt: joinReceiptTraceStatus(for: cidString),
                        groupLoaded: false,
                        eventEpoch: data.epoch
                    )
                    log.debug("[E2eSync] state=commit_skipped reason=group_missing", subsystems: .mls)
                    return .requiresCursorAdvance
                }
                guard let bytes = data.commit else {
                    throw E2eeSyncApplyError.missingProtocolPayload(type: data.type)
                }
                let commitData = Data(bytes)
                let ciphertextHash = Data(SHA256.hash(data: commitData))
                guard data.epoch > 0 else {
                    let localEpoch = try self.mlsClient.loadGroup(with: cidString).epoch()
                    throw E2eeSyncApplyError.epochMismatch(local: localEpoch, event: data.epoch)
                }
                let targetEpoch = UInt64(data.epoch)
                let existingProof = try durableInboxStore.commitPersistenceProof(
                    accountId: accountId,
                    scopeCid: cidString,
                    eventId: eventId
                )
                if let existingProof {
                    guard existingProof.ciphertextHash == ciphertextHash,
                          existingProof.targetEpoch == targetEpoch else {
                        throw E2eeSyncApplyError.invalidCommit(
                            reason: "ciphertext hash or target epoch does not match durable proof"
                        )
                    }
                }

                let group = try self.mlsClient.loadGroup(with: cidString)
                let localEpoch = group.epoch()
                let epochAction = E2eeCommitEpochAction.resolve(
                    localEpoch: localEpoch,
                    targetEpoch: targetEpoch
                )
                let epochActionName: String
                switch epochAction {
                case .supersedeHistorical: epochActionName = "supersede_historical"
                case .finalizeActive: epochActionName = "finalize_active"
                case .processNext: epochActionName = "process_next"
                case .blockGap: epochActionName = "block_gap"
                }
                trace.info(
                    stage: "commit_epoch_classified",
                    source: "scope_sync",
                    protocolType: data.type.rawValue,
                    result: epochActionName,
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: true,
                    eventEpoch: data.epoch,
                    localEpoch: localEpoch
                )
                switch epochAction {
                case .supersedeHistorical:
                    try durableInboxStore.markCommitSuperseded(
                        accountId: accountId,
                        scopeCid: cidString,
                        envelope: envelope,
                        ciphertextHash: ciphertextHash,
                        targetEpoch: targetEpoch
                    )
                    durableApplyLock.lock()
                    blockedDurableScopes.remove(cidString)
                    durableApplyLock.unlock()
                    log.warning(
                        "[E2eSync] state=historical_commit_superseded target_epoch=\(targetEpoch) local_epoch=\(localEpoch)",
                        subsystems: .mls
                    )
                    return .cursorAdvancedAtomically
                case .finalizeActive:
                    break
                case .processNext:
                    break
                case .blockGap:
                    throw E2eeSyncApplyError.epochMismatch(local: localEpoch, event: data.epoch)
                }

                try durableInboxStore.markCommitProofPersisted(
                    accountId: accountId,
                    scopeCid: cidString,
                    eventId: eventId,
                    ciphertextHash: ciphertextHash,
                    targetEpoch: targetEpoch
                )
                if existingProof?.mlsStatePersisted == true,
                   localEpoch != targetEpoch {
                    throw E2eeSyncApplyError.invalidCommit(
                        reason: "provider epoch disagrees with completed durable proof"
                    )
                }
                if localEpoch == targetEpoch {
                    let receipt = try durableInboxStore.localJoinReceiptProof(
                        accountId: accountId,
                        scopeCid: cidString
                    )
                    let receiptMatches = receipt.map {
                        $0.status == .merged &&
                            $0.commitHash == ciphertextHash &&
                            $0.epoch == targetEpoch &&
                            $0.requestDeviceId == data.deviceId &&
                            data.user.id == accountId
                    } ?? false
                    let isOwnCommit = data.deviceId.flatMap { eventDeviceId in
                        data.user.id == accountId &&
                            mlsClient.ownsDeviceId(eventDeviceId, userId: accountId)
                    } ?? false
                    guard existingProof != nil || receiptMatches || isOwnCommit else {
                        throw E2eeSyncApplyError.invalidCommit(
                            reason: "target epoch is already active without a prior proof"
                        )
                    }
                    try durableInboxStore.markCommitStatePersisted(
                        accountId: accountId,
                        scopeCid: cidString,
                        eventId: eventId,
                        ciphertextHash: ciphertextHash,
                        targetEpoch: targetEpoch
                    )
                    log.debug("[MLS] Commit replay proven at epoch \(localEpoch)", subsystems: .mls)
                    if data.type == .externalCommit,
                       (receiptMatches || isOwnCommit),
                       let deviceId = data.deviceId {
                        trace.info(
                            stage: "external_commit_finalize_selected",
                            source: "scope_sync",
                            protocolType: data.type.rawValue,
                            result: "finalize_receipt_and_boundary",
                            receipt: joinReceiptTraceStatus(for: cidString),
                            groupLoaded: true,
                            eventEpoch: data.epoch,
                            localEpoch: localEpoch
                        )
                        return .finalizeExternalJoin(
                            commitHash: ciphertextHash,
                            epoch: targetEpoch,
                            deviceId: deviceId,
                            requireReceipt: receiptMatches
                        )
                    }
                    return .requiresCursorAdvance
                }

                log.debug("[MLS] Processing commit message", subsystems: .mls)
                let processed: MlsProcessedProtocolMessage
                do {
                    processed = try mlsClient.processProtocolMessage(
                        data: commitData,
                        in: group,
                        serverAcceptedAt: envelope.createdAt
                    )
                } catch {
                    emitMlsRolloutMetric(
                        .init(name: .delayedCommit, outcome: .failure, reason: .processError)
                    )
                    throw error
                }
                guard case .commit(let metadata) = processed else {
                    throw E2eeSyncApplyError.invalidCommit(
                        reason: "OpenMLS returned a proposal for a commit envelope"
                    )
                }
                guard metadata.groupEpochAfter == targetEpoch,
                      group.epoch() == targetEpoch else {
                    throw E2eeSyncApplyError.epochMismatch(
                        local: metadata.groupEpochAfter,
                        event: data.epoch
                    )
                }
                try mlsClient.saveState(of: group)
                try durableInboxStore.markCommitStatePersisted(
                    accountId: accountId,
                    scopeCid: cidString,
                    eventId: eventId,
                    ciphertextHash: ciphertextHash,
                    targetEpoch: targetEpoch
                )
                if let cid = try? ChannelId(cid: cidString) {
                    reDecryptPendingMessages(in: cid)
                }
                trace.info(
                    stage: "commit_applied",
                    source: "scope_sync",
                    protocolType: data.type.rawValue,
                    result: "state_persisted",
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: true,
                    eventEpoch: data.epoch,
                    localEpoch: group.epoch()
                )
                return .requiresCursorAdvance
            case .welcome:
                
                guard !self.shouldSkipWelcome(
                    cid: cidString,
                    incomingGeneration: data.groupGeneration
                ) else {
                    trace.info(
                        stage: "welcome_skipped",
                        source: "scope_sync",
                        protocolType: data.type.rawValue,
                        result: "cursor_advance",
                        reason: "group_exists",
                        receipt: joinReceiptTraceStatus(for: cidString),
                        groupLoaded: true,
                        eventEpoch: data.epoch
                    )
                    log.debug("[MLS] state=welcome_skipped reason=group_exists", subsystems: .mls)
                    if let existingCid = try? ChannelId(cid: cidString) {
                        // A prior attempt may have persisted the group and then failed its Core
                        // Data normalization. Retry that durable metadata write before advancing
                        // the exact Welcome cursor.
                        try normalizeHistoricalApplicationsAndWait(cid: existingCid)
                    }
                    return .requiresCursorAdvance
                }
                if let targetUserIds = data.targetUserIds,
                   let currentUserId = mlsClient.userId,
                   !targetUserIds.contains(currentUserId) {
                    trace.info(
                        stage: "welcome_skipped",
                        source: "scope_sync",
                        protocolType: data.type.rawValue,
                        result: "cursor_advance",
                        reason: "not_targeted",
                        receipt: joinReceiptTraceStatus(for: cidString),
                        groupLoaded: mlsClient.isGroupLoaded(cid: cidString),
                        targetedAtCurrentUser: false,
                        eventEpoch: data.epoch
                    )
                    log.debug("[E2eSync] Skipping welcome not targeted at current user", subsystems: .mls)
                    return .requiresCursorAdvance
                }
                if let targetDeviceIds = data.targetDeviceIds,
                   let currentDeviceId = mlsClient.currentDeviceId,
                   !targetDeviceIds.contains(currentDeviceId) {
                    return .requiresCursorAdvance
                }
                trace.info(
                    stage: "welcome_processing",
                    source: "scope_sync",
                    protocolType: data.type.rawValue,
                    receipt: joinReceiptTraceStatus(for: cidString),
                    groupLoaded: false,
                    targetedAtCurrentUser: targetedAtCurrentUser,
                    eventEpoch: data.epoch
                )
                log.debug("[MLS] state=welcome_processing", subsystems: .mls)
                guard let welcome = data.welcome, let tree = data.ratchetTree else {
                    throw E2eeSyncApplyError.missingProtocolPayload(type: data.type)
                }
                let ratchetTree = try RatchetTree.fromBytes(data: Data(tree))
                do {
                    try mlsClient.joinWithWelcome(
                        cid: cidString,
                        welcome: Data(welcome),
                        ratchetTree: ratchetTree,
                        generation: incomingGeneration,
                        groupId: data.groupId.map { Data($0) }
                    )
                    try saveMlsGroupJoinedAtAndWait(cidString: cidString)
                    try durableInboxStore.clearNoMatchingKeyPackageJoinPrerequisite(
                        accountId: accountId,
                        scopeCid: cidString
                    )
                    let localEpoch = try mlsClient.loadGroup(with: cidString).epoch()
                    trace.info(
                        stage: "welcome_joined",
                        source: "scope_sync",
                        protocolType: data.type.rawValue,
                        result: "anchor_persisted",
                        receipt: joinReceiptTraceStatus(for: cidString),
                        groupLoaded: true,
                        eventEpoch: data.epoch,
                        localEpoch: localEpoch
                    )
                    if let joinedCid = try? ChannelId(cid: cidString) {
                        try normalizeHistoricalApplicationsAndWait(cid: joinedCid)
                        reDecryptPendingMessages(in: joinedCid)
                    }
                } catch {
                    if isMissingKeyPackageError(error) {
                        // Expected on a reinstall/new device: the historical Welcome targets a
                        // KeyPackage owned by another installation. The bootstrap coordinator
                        // observes that no group was created and performs external join.
                        try durableInboxStore.recordNoMatchingKeyPackageJoinPrerequisite(
                            accountId: accountId,
                            scopeCid: cidString,
                            eventId: eventId
                        )
                        log.warning(
                            "[E2eSync] state=welcome_skipped reason=no_matching_keypackage",
                            subsystems: .mls
                        )
                        trace.info(
                            stage: "welcome_skipped",
                            source: "scope_sync",
                            protocolType: data.type.rawValue,
                            result: "external_join_required",
                            reason: "no_matching_keypackage",
                            receipt: joinReceiptTraceStatus(for: cidString),
                            groupLoaded: mlsClient.isGroupLoaded(cid: cidString),
                            eventEpoch: data.epoch
                        )
                        // Invite-time scope sync is also used outside bootstrap. Wake
                        // the existing coordinator after the prerequisite is durable;
                        // otherwise this new group waits until the next app startup.
                        let recoveryCid = try ChannelId(cid: cidString)
                        trace.info(
                            stage: "welcome_fallback_requested",
                            source: "scope_sync",
                            reason: "no_matching_keypackage",
                            groupLoaded: mlsClient.isGroupLoaded(cid: cidString)
                        )
                        enqueueBootstrap(for: recoveryCid)
                        return .requiresCursorAdvance
                    }
                    trace.failure(
                        stage: "welcome_join_failed",
                        source: "scope_sync",
                        error: error,
                        protocolType: data.type.rawValue,
                        receipt: joinReceiptTraceStatus(for: cidString),
                        groupLoaded: mlsClient.isGroupLoaded(cid: cidString),
                        eventEpoch: data.epoch
                    )
                    throw error
                }
                return .requiresCursorAdvance
            case .proposal:
                throw E2eeSyncApplyError.unsupportedEvent(type: "protocol.proposal")
        }
    }
    
    private func saveSyncCursors(_ cursors: [String: ScopeSyncCursorPayload]) {
        saveE2eSyncCursorsToUserDefaults(cursors)
    }

    private func isMissingKeyPackageError(_ error: Error) -> Bool {
        guard let mlsError = error as? MlsError else { return false }
        if case .NoMatchingKeyPackage = mlsError { return true }
        return false
    }
    
    /// Records the current timestamp as the moment this device joined the MLS group for the given channel.
    /// Called after a successful external join or welcome-based join.
    private func saveMlsGroupJoinedAt(cidString: String, completion: ((Error?) -> Void)? = nil) {
        guard let epoch = try? mlsClient.loadGroup(with: cidString).epoch() else {
            completion?(ClientError.Unexpected("Unable to persist Welcome join epoch."))
            return
        }
        database.write { session in
            guard let cid = try? ChannelId(cid: cidString),
                  let dto = session.channel(cid: cid) else { return }
            dto.mlsGroupJoinedAt = Date().bridgeDate
            dto.mlsFirstDecryptableEpoch = NSNumber(value: epoch)
        } completion: { error in
            if let error {
                log.error(
                    "[E2eSync] state=group_join_timestamp_save_failed "
                        + PrivacySafeLogMetadata.errorFields(error),
                    subsystems: .mls
                )
            }
            completion?(error)
        }
    }

    private func saveMlsGroupJoinedAtAndWait(cidString: String) throws {
        let epoch = try mlsClient.loadGroup(with: cidString).epoch()
        try database.writeAndWait { session in
            guard let cid = try? ChannelId(cid: cidString),
                  let dto = session.channel(cid: cid) else { return }
            dto.mlsGroupJoinedAt = Date().bridgeDate
            dto.mlsFirstDecryptableEpoch = NSNumber(value: epoch)
        }
    }

    private func backfillFirstDecryptableEpochIfNeeded(
        cidString: String,
        verifiedEpoch: UInt64
    ) throws {
        guard verifiedEpoch <= UInt64(Int64.max) else {
            throw ClientError.Unexpected("Verified MLS join epoch exceeds local storage range.")
        }
        try database.writeAndWait { session in
            guard let cid = try? ChannelId(cid: cidString),
                  let dto = session.channel(cid: cid),
                  dto.mlsFirstDecryptableEpoch == nil else { return }
            dto.mlsFirstDecryptableEpoch = NSNumber(value: verifiedEpoch)
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
                log.error(
                    "[MLS] state=key_consume_failed \(PrivacySafeLogMetadata.errorFields(error))"
                )
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
                log.error(
                    "[MLS] state=keypackage_consume_failed target_count=\(targetUserIds.count) "
                        + PrivacySafeLogMetadata.errorFields(error)
                )
                completion(.failure(error))
            }
        })
    }
    
    func addMember(to cid: ChannelId, memberKeypackages: [KeyPackage]) throws -> (CommitBundle, RatchetTree, Data, Int) {
        try performMlsMutation(cidString: cid.rawValue) {
            let group = try self.mlsClient.loadOrCreateGroup(with: cid.rawValue)
            let commitBundle = try self.mlsClient.addMember(
                to: group,
                memberKeyPackages: memberKeypackages
            )

            let ratchetTree = group.exportRatchetTree()

            guard let groupInfo = commitBundle.groupInfo else {
                throw ClientError("[MLS] add member failed, no group info in commit bundle")
            }
            let epoch = Int(group.epoch())
            log.debug("TTTTTTTT ADD MEMBER CURRENT EPOCH: \(epoch)")
            return (commitBundle, ratchetTree, groupInfo, epoch)
        }
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
        try performMlsMutation(cidString: cid.rawValue) {
            let (commitBundle, ratchetTree, epoch) = try self.mlsClient.addMembersWithRemovals(
                in: cid.rawValue,
                removeUserIds: removeUserIds,
                addMembers: memberKeypackages
            )
            guard let groupInfo = commitBundle.groupInfo else {
                throw ClientError("[MLS] add member with removals failed, no group info in commit bundle")
            }
            log.debug(
                "[MLS] state=member_add_with_removals_created epoch=\(epoch) removal_count=\(removeUserIds.count)"
            )
            return (commitBundle, ratchetTree, groupInfo, epoch)
        }
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
            // Create the pending removal commit and capture its network payload as one mutation.
            let (commitBundle, groupInfo, preMergeEpoch) = try removeMembers(
                targetUserIds,
                in: cid
            )

            guard !groupInfo.isEmpty else {
                try clearPendingCommit(in: cid)
                log.error("[E2E] state=eviction_commit_failed reason=group_info_missing", subsystems: .mls)
                return
            }

            let body = CommitEvictionRequestBody(
                targetUserIds: targetUserIds,
                commit: commitBundle.commit,
                groupInfo: groupInfo,
                epoch: preMergeEpoch
            )

            log.debug(
                "[E2E] state=eviction_commit_sending target_count=\(targetUserIds.count) epoch=\(preMergeEpoch)",
                subsystems: .mls
            )

            apiClient.request(endpoint: .commitEviction(cid: cid, body: body)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // 6. Server OK → merge commit, clear pending ghost queue, persist.
                    do {
                        try self.mergePendingCommit(in: cid)
                        self.deletePendingRemoveMembers(userIds: targetUserIds, channelCid: cidString)
                        log.debug(
                            "[E2E] state=eviction_commit_succeeded target_count=\(targetUserIds.count)",
                            subsystems: .mls
                        )
                    } catch {
                        log.error(
                            "[E2E] state=eviction_commit_merge_failed "
                                + PrivacySafeLogMetadata.errorFields(error),
                            subsystems: .mls
                        )
                    }
                case .failure(let error):
                    // 7. Fail → rollback, persist cleanup.
                    do {
                        try self.clearPendingCommit(in: cid)
                    } catch {
                        log.error(
                            "[E2E] state=eviction_commit_clear_failed "
                                + PrivacySafeLogMetadata.errorFields(error),
                            subsystems: .mls
                        )
                    }
                    log.error(
                        "[E2E] state=eviction_commit_failed "
                            + PrivacySafeLogMetadata.errorFields(error),
                        subsystems: .mls
                    )
                }
            }
        } catch {
            log.error(
                "[E2E] state=eviction_commit_create_failed "
                    + PrivacySafeLogMetadata.errorFields(error),
                subsystems: .mls
            )
        }
    }

    func removeMembers(_ userIds: [String], in cid: ChannelId) throws -> (CommitBundle, Data, Int) {
        try performMlsMutation(cidString: cid.rawValue) {
            let group = try self.mlsClient.loadGroup(with: cid.rawValue)
            let commitBundle = try self.mlsClient.removeMembers(userIds, in: group)
            guard let groupInfo = commitBundle.groupInfo else {
                throw ClientError("[MLS] Remove member failed, no group info in commit bundle")
            }
            let epoch = Int(group.epoch())
            log.debug("TTTTTTTT REMOVE MEMBER CURRENT EPOCH: \(epoch)")
            return (commitBundle, groupInfo, epoch)
        }
    }
    
    private var groupInfoRepairScope: GroupInfoRepairScope? {
        guard let accountId = mlsClient.userId, let deviceId = mlsClient.currentDeviceId else { return nil }
        return .init(accountId: accountId, deviceId: deviceId)
    }

    private func handleGroupInfoRefreshRequested(_ event: GroupInfoRefreshRequestedEvent) {
        guard mlsRolloutControls.groupInfoRepairEnabled else { return }
        guard let scope = groupInfoRepairScope else { return }
        guard groupInfoRepairCoordinator.enqueue(scope: scope, cid: event.cid.rawValue, request: event.request) else {
            return
        }
        processGroupInfoRefresh(cid: event.cid, request: event.request, attempt: 0)
    }

    private func handleGroupInfoUploaded(_ event: GroupInfoUploadedEvent) {
        guard mlsRolloutControls.groupInfoRepairEnabled else { return }
        guard let scope = groupInfoRepairScope else { return }
        groupInfoRepairCoordinator.clearUploaded(
            scope: scope,
            cid: event.cid.rawValue,
            requestId: event.requestId,
            epoch: event.epoch
        )
        groupInfoRepairCoordinator.finish(cid: event.cid.rawValue)
    }

    private func reconcilePendingGroupInfoRepairs() {
        guard mlsRolloutControls.groupInfoRepairEnabled else { return }
        guard let scope = groupInfoRepairScope else { return }
        let pending = groupInfoRepairCoordinator.pending(scope: scope)
        var cids = Set(pending.map(\.cid))
        if let storedCids = try? mlsClient.getStoredGroupIdList() {
            cids.formUnion(storedCids)
        }
        for cidString in cids {
            guard let cid = try? ChannelId(cid: cidString) else {
                groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cidString)
                continue
            }
            apiClient.request(endpoint: .getGroupInfoRefresh(cid: cid)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let response):
                    guard let request = response.request else {
                        self.groupInfoRepairCoordinator.clearUploaded(
                            scope: scope,
                            cid: cidString,
                            requestId: "reconciled",
                            epoch: Int.max
                        )
                        return
                    }
                    guard self.groupInfoRepairCoordinator.enqueue(
                        scope: scope,
                        cid: cidString,
                        request: request
                    ) else { return }
                    self.processGroupInfoRefresh(cid: cid, request: request, attempt: 0)
                case .failure(let error):
                    if GroupInfoRepairCoordinator.shouldClearAfterServerFailure(error) {
                        self.groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cidString)
                    } else {
                        self.groupInfoRepairCoordinator.emitRetryable(cid: cidString, delay: nil)
                    }
                }
            }
        }
    }

    private func processGroupInfoRefresh(
        cid: ChannelId,
        request: GroupInfoRefreshRequestPayload,
        attempt: Int
    ) {
        guard mlsRolloutControls.groupInfoRepairEnabled else { return }
        guard request.expiresAt > Date() else {
            groupInfoRepairCoordinator.finish(cid: cid.rawValue)
            return
        }
        apiClient.request(endpoint: .claimGroupInfoRefresh(cid: cid, requestId: request.requestId)) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if GroupInfoRepairCoordinator.shouldClearAfterServerFailure(error),
                   let scope = self.groupInfoRepairScope {
                    self.groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cid.rawValue)
                } else {
                    self.scheduleGroupInfoRepairRetry(cid: cid, request: request, attempt: attempt)
                }
            case .success(let lease):
                guard let leaseToken = lease.leaseToken else {
                    self.scheduleGroupInfoRepairRetry(cid: cid, request: request, attempt: attempt)
                    return
                }
                let material: (Data, Int)
                do {
                    material = try self.performMlsMutation(cidString: cid.rawValue) {
                        let group = try self.mlsClient.loadGroup(with: cid.rawValue)
                        let epoch = Int(group.epoch())
                        guard epoch >= request.minimumEpoch else {
                            throw ClientError("Local MLS epoch is behind GroupInfo refresh minimum")
                        }
                        let groupInfo = try self.mlsClient.exportGroupInfo(of: group)
                        guard !groupInfo.isEmpty, groupInfo.count <= 1_048_576 else {
                            throw ClientError("Exported GroupInfo violates the 1 MiB contract")
                        }
                        return (groupInfo, epoch)
                    }
                } catch {
                    self.scheduleGroupInfoRepairRetry(cid: cid, request: request, attempt: attempt)
                    return
                }
                let body = UploadGroupInfoRequestBody(
                    groupInfo: material.0,
                    epoch: material.1,
                    requestId: request.requestId,
                    leaseToken: leaseToken
                )
                self.apiClient.request(endpoint: .uploadGroupInfo(cid: cid, body: body)) { [weak self] uploadResult in
                    guard let self else { return }
                    switch uploadResult {
                    case .failure(let error):
                        if GroupInfoRepairCoordinator.shouldClearAfterServerFailure(error),
                           let scope = self.groupInfoRepairScope {
                            self.groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cid.rawValue)
                        } else {
                            self.scheduleGroupInfoRepairRetry(cid: cid, request: request, attempt: attempt)
                        }
                    case .success:
                        self.apiClient.request(endpoint: .getGroupInfoRefresh(cid: cid)) { [weak self] reconcileResult in
                            guard let self else { return }
                            switch reconcileResult {
                            case .success(let response) where response.request == nil:
                                guard let scope = self.groupInfoRepairScope else { return }
                                self.groupInfoRepairCoordinator.clearUploaded(
                                    scope: scope,
                                    cid: cid.rawValue,
                                    requestId: request.requestId,
                                    epoch: material.1
                                )
                                self.groupInfoRepairCoordinator.finish(cid: cid.rawValue)
                            case .failure(let error)
                                where GroupInfoRepairCoordinator.shouldClearAfterServerFailure(error):
                                guard let scope = self.groupInfoRepairScope else { return }
                                self.groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cid.rawValue)
                            default:
                                self.scheduleGroupInfoRepairRetry(cid: cid, request: request, attempt: attempt)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scheduleGroupInfoRepairRetry(
        cid: ChannelId,
        request: GroupInfoRefreshRequestPayload,
        attempt: Int
    ) {
        guard let retryDelay = groupInfoRepairCoordinator.retryDelay(attempt: attempt) else {
            groupInfoRepairCoordinator.emitRetryable(cid: cid.rawValue, delay: nil)
            groupInfoRepairCoordinator.finish(cid: cid.rawValue)
            return
        }
        groupInfoRepairCoordinator.emitRetryable(cid: cid.rawValue, delay: retryDelay)
        DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            self?.processGroupInfoRefresh(cid: cid, request: request, attempt: attempt + 1)
        }
    }

    private func reportGroupInfoFailure(cid: ChannelId, groupInfo: GroupInfoPayload, reason: String) {
        guard mlsRolloutControls.groupInfoRepairEnabled else { return }
        let body = ReportGroupInfoFailureRequestBody(
            reason: reason,
            observedEpoch: groupInfo.epoch,
            observedHash: groupInfo.hash
        )
        apiClient.request(endpoint: .reportGroupInfoFailure(cid: cid, body: body)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                if let request = response.request,
                   let scope = self.groupInfoRepairScope,
                   self.groupInfoRepairCoordinator.enqueue(scope: scope, cid: cid.rawValue, request: request) {
                    self.processGroupInfoRefresh(cid: cid, request: request, attempt: 0)
                }
                self.groupInfoRepairCoordinator.emitRetryable(cid: cid.rawValue, delay: nil)
            case .failure(let error):
                if GroupInfoRepairCoordinator.shouldClearAfterServerFailure(error),
                   let scope = self.groupInfoRepairScope {
                    self.groupInfoRepairCoordinator.clearRemoved(scope: scope, cid: cid.rawValue)
                } else {
                    self.groupInfoRepairCoordinator.emitRetryable(cid: cid.rawValue, delay: nil)
                }
            }
        }
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
    func externalJoinChannel(
        cid: ChannelId,
        retriesRemaining: Int = 3,
        requiresActiveMemberRecovery: Bool = false,
        replaceRetainedGroup: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        trace.info(
            stage: "external_join_started",
            source: "external_join",
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
            retriesRemaining: retriesRemaining
        )
        if (!replaceRetainedGroup || hasLocalJoinReceipt(for: cid.rawValue)),
           recoverExternalJoinIfNeeded(cid: cid, completion: completion) {
            trace.info(
                stage: "external_join_recovery_selected",
                source: "recovery",
                receipt: joinReceiptTraceStatus(for: cid.rawValue),
                groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
                retriesRemaining: retriesRemaining
            )
            return
        }
        trace.info(
            stage: "group_info_requested",
            source: "external_join",
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
            retriesRemaining: retriesRemaining
        )
        apiClient.request(endpoint: .getGroupInfo(cid: cid)) { [weak self] (result: Result<GroupInfoPayload, Error>) in
            guard let self else {
                return
            }
            switch result {
            case .success(let groupInfo):
                guard groupInfo.isValidExternalJoinIdentity(installedGeneration: self.groupGeneration(for: cid)) else {
                    completion(ClientError("Invalid external join generation identity."))
                    return
                }
                trace.info(
                    stage: "group_info_received",
                    source: "external_join",
                    result: groupInfo.isStale ? "stale" : "fresh",
                    receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                    retriesRemaining: retriesRemaining
                )
                guard !groupInfo.isStale else {
                    guard self.mlsRolloutControls.groupInfoRepairEnabled else {
                        completion(ClientError("Group info is stale and GroupInfo repair is disabled."))
                        return
                    }
                    self.reportGroupInfoFailure(cid: cid, groupInfo: groupInfo, reason: "group_info_stale")
                    guard retriesRemaining > 0 else {
                        trace.info(
                            stage: "external_join_failed",
                            source: "external_join",
                            result: "failed",
                            reason: "group_info_stale",
                            receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                            groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                            retriesRemaining: 0
                        )
                        log.error(
                            "[E2E] state=external_join_failed reason=group_info_stale retries_remaining=0",
                            subsystems: .mls
                        )
                        completion(ClientError("Group info is stale; no fresh group_info available yet."))
                        return
                    }
                    let retryAttempt = max(0, 3 - retriesRemaining)
                    guard let delaySeconds = self.groupInfoRepairCoordinator.retryDelay(attempt: retryAttempt) else {
                        completion(ClientError("Group info is stale; refresh retry budget exhausted."))
                        return
                    }
                    trace.info(
                        stage: "external_join_retry_scheduled",
                        source: "external_join",
                        result: "retry",
                        reason: "group_info_stale",
                        receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                        retriesRemaining: retriesRemaining,
                        delaySeconds: Int(delaySeconds)
                    )
                    log.debug(
                        "[E2E] state=external_join_retry reason=group_info_stale delay_seconds=\(Int(delaySeconds)) retries_remaining=\(retriesRemaining)",
                        subsystems: .mls
                    )
                    DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                        self?.externalJoinChannel(cid: cid, retriesRemaining: retriesRemaining - 1, requiresActiveMemberRecovery: requiresActiveMemberRecovery, replaceRetainedGroup: replaceRetainedGroup, completion: completion)
                    }
                    return
                }
                if requiresActiveMemberRecovery,
                   !groupInfo.authorizesActiveMemberRecovery {
                    completion(ClientError("External join requires an active member recovery prerequisite."))
                    return
                }
                do {
                    // Re-check inside the mutation executor: a queued Welcome may have created
                    // the group while the group_info request was in flight.
                    let externalJoinResult: ExternalJoinResult? = try performMlsMutation(cidString: cid.rawValue) {
                        if replaceRetainedGroup {
                            guard requiresActiveMemberRecovery, self.hasRetainedReplayBlock(cid.rawValue),
                                  let retained = try? self.mlsClient.loadGroup(with: cid.rawValue),
                                  retained.epoch() < UInt64(groupInfo.epoch) else {
                                throw ClientError.Unexpected("Retained recovery is not authorized.")
                            }
                            return try self.mlsClient.externalJoinIsolated(cid: cid.rawValue,
                                generation: UInt64(groupInfo.groupGeneration), groupInfo: groupInfo.groupInfo.data,
                                expectedGroupId: groupInfo.groupId.map { Data($0) })
                        }
                        guard !self.mlsClient.isGroupLoaded(cid: cid.rawValue) else { return nil }
                        return try self.mlsClient.externalJoin(
                            groupInfo: groupInfo.groupInfo.data,
                            expectedGroupId: groupInfo.groupId.map { Data($0) }
                        )
                    }
                    guard let externalJoinResult else {
                        trace.info(
                            stage: "external_join_finished",
                            source: "external_join",
                            result: "welcome_won_race",
                            receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                            groupLoaded: true,
                            retriesRemaining: retriesRemaining
                        )
                        completion(nil)
                        return
                    }
                    log.debug(
                        "[E2E] state=external_join_group_created epoch=\(externalJoinResult.group.epoch())",
                        subsystems: .mls
                    )
                    trace.info(
                        stage: "external_join_group_created",
                        source: "external_join",
                        result: "pending_commit_created",
                        receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                        groupLoaded: true,
                        localEpoch: externalJoinResult.group.epoch(),
                        retriesRemaining: retriesRemaining
                    )
                    requestExternalJoin(
                        to: cid,
                        externalJoinResult: externalJoinResult,
                        groupGeneration: groupInfo.groupGeneration,
                        groupId: groupInfo.groupId.map { Data($0) },
                        completion: completion
                    )
                } catch (let error) {
                    try? self.performMlsMutation(cidString: cid.rawValue) {
                        if !replaceRetainedGroup, self.mlsClient.isGroupLoaded(cid: cid.rawValue) {
                            try self.mlsClient.deleteGroup(cid: cid.rawValue)
                        }
                    }
                    guard self.mlsRolloutControls.groupInfoRepairEnabled else {
                        completion(error)
                        return
                    }
                    self.reportGroupInfoFailure(cid: cid, groupInfo: groupInfo, reason: "group_info_invalid")
                    trace.failure(
                        stage: "external_join_group_info_failed",
                        source: "external_join",
                        error: error,
                        receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                    )
                    log.error(
                        "[E2E] state=external_join_group_info_failed "
                            + PrivacySafeLogMetadata.errorFields(error),
                        subsystems: .mls
                    )
                    let retryAttempt = max(0, 3 - retriesRemaining)
                    if retriesRemaining > 0,
                       let delaySeconds = self.groupInfoRepairCoordinator.retryDelay(attempt: retryAttempt) {
                        self.groupInfoRepairCoordinator.emitRetryable(cid: cid.rawValue, delay: delaySeconds)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                            self?.externalJoinChannel(
                                cid: cid,
                                retriesRemaining: retriesRemaining - 1,
                                requiresActiveMemberRecovery: requiresActiveMemberRecovery,
                                replaceRetainedGroup: replaceRetainedGroup,
                                completion: completion
                            )
                        }
                    } else {
                        completion(error)
                    }
                    return
                }
            case .failure(let error):
                trace.failure(
                    stage: "group_info_request_failed",
                    source: "external_join",
                    error: error,
                    receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue)
                )
                completion(error)
            }
        }
    }

    /// Recovers the durable external-join boundary before issuing another mutation.
    /// Returns `true` when the call completed (or is completing) without a fresh request.
    private func recoverExternalJoinIfNeeded(
        cid: ChannelId,
        completion: @escaping (Error?) -> Void
    ) -> Bool {
        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        guard let accountId = mlsClient.userId else { return false }
        let proof: E2eeDurableInboxStore.LocalJoinReceiptProof?
        do {
            proof = try durableInboxStore.localJoinReceiptProof(
                accountId: accountId,
                scopeCid: cid.rawValue
            )
        } catch {
            trace.failure(
                stage: "join_receipt_read_failed",
                source: "recovery",
                error: error,
                receipt: "unavailable",
                groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue)
            )
            completion(error)
            return true
        }

        guard let proof else {
            if mlsClient.isGroupLoaded(cid: cid.rawValue) {
                trace.info(
                    stage: "external_join_recovery_finished",
                    source: "recovery",
                    result: "group_already_loaded",
                    receipt: "none",
                    groupLoaded: true
                )
                completion(nil)
                return true
            }
            return false
        }

        trace.info(
            stage: "join_receipt_recovery_started",
            source: "recovery",
            receipt: proof.status.rawValue,
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
            localEpoch: proof.epoch
        )
        switch proof.status {
        case .merged:
            guard mlsClient.isGroupLoaded(cid: cid.rawValue) else {
                try? durableInboxStore.discardLocalJoinReceipt(accountId: accountId, scopeCid: cid.rawValue)
                trace.info(
                    stage: "join_receipt_discarded",
                    source: "recovery",
                    result: "fresh_join_required",
                    reason: "merged_group_missing",
                    receipt: "none",
                    groupLoaded: false
                )
                return false
            }
            trace.info(
                stage: "external_join_recovery_finished",
                source: "recovery",
                result: "awaiting_external_commit",
                receipt: proof.status.rawValue,
                groupLoaded: true,
                localEpoch: proof.epoch
            )
            completion(nil)
            return true
        case .serverAccepted:
            guard mlsClient.isGroupLoaded(cid: cid.rawValue) else {
                try? durableInboxStore.discardLocalJoinReceipt(accountId: accountId, scopeCid: cid.rawValue)
                trace.info(
                    stage: "join_receipt_discarded",
                    source: "recovery",
                    result: "fresh_join_required",
                    reason: "accepted_group_missing",
                    receipt: "none",
                    groupLoaded: false
                )
                return false
            }
            do {
                let (groupInfo, epoch) = try performMlsMutation(cidString: cid.rawValue) {
                    try self.mlsClient.mergePendingCommit(in: cid)
                    let group = try self.mlsClient.loadGroup(with: cid.rawValue)
                    return (try self.mlsClient.exportGroupInfo(of: group), group.epoch())
                }
                try durableInboxStore.markLocalJoinMerged(
                    accountId: accountId,
                    scopeCid: cid.rawValue,
                    firstDecryptableEpoch: epoch
                )
                if let marker = mlsClient.loadPendingGenerationJoin(cid: cid.rawValue),
                   marker.status == "external_join_prepared" {
                    try mlsClient.saveGenerationMarker(
                        .init(
                            cid: marker.cid,
                            generation: marker.generation,
                            groupId: marker.groupId,
                            epoch: epoch,
                            status: "active",
                            operationId: marker.operationId
                        )
                    )
                    mlsClient.removePendingGenerationJoin(cid: cid.rawValue)
                }
                normalizeHistoricalApplications(cid: cid)
                trace.info(
                    stage: "external_join_recovery_merged",
                    source: "recovery",
                    result: "group_info_publish_required",
                    receipt: "merged",
                    groupLoaded: true,
                    localEpoch: epoch
                )
                uploadGroupInfo(
                    in: cid,
                    groupInfo: groupInfo,
                    epoch: Int(epoch),
                    completion: completion
                )
            } catch {
                trace.failure(
                    stage: "external_join_recovery_failed",
                    source: "recovery",
                    error: error,
                    receipt: joinReceiptTraceStatus(for: cid.rawValue),
                    groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue)
                )
                completion(error)
            }
            return true
        case .prepared, .finalized:
            try? performMlsMutation(cidString: cid.rawValue) {
                try? self.mlsClient.clearPendingCommit(in: cid)
                if self.mlsClient.isGroupLoaded(cid: cid.rawValue) {
                    try self.mlsClient.deleteGroup(cid: cid.rawValue)
                }
            }
            try? durableInboxStore.discardLocalJoinReceipt(accountId: accountId, scopeCid: cid.rawValue)
            mlsClient.removePendingGenerationJoin(cid: cid.rawValue)
            trace.info(
                stage: "join_receipt_discarded",
                source: "recovery",
                result: "fresh_join_required",
                reason: proof.status == .prepared ? "prepared_unproven" : "finalized_stale",
                receipt: "none",
                groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
                localEpoch: proof.epoch
            )
            return false
        }
    }
    
    private func requestExternalJoin(
        to cid: ChannelId,
        externalJoinResult: ExternalJoinResult,
        groupGeneration: Int,
        groupId: Data?,
        completion: @escaping (Error?) -> Void
    ) {
        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        guard let accountId = mlsClient.userId,
              let requestDeviceId = mlsClient.currentDeviceId else {
            let error = ClientError.Unexpected("External join requires an authenticated MLS device.")
            trace.failure(
                stage: "external_join_identity_missing",
                source: "external_join",
                error: error,
                receipt: joinReceiptTraceStatus(for: cid.rawValue),
                groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue)
            )
            completion(error)
            return
        }
        let targetEpoch = externalJoinResult.group.epoch()
        let commitHash = Data(SHA256.hash(data: Data(externalJoinResult.commit)))
        trace.info(
            stage: "join_receipt_preparing",
            source: "external_join",
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            groupLoaded: true,
            localEpoch: targetEpoch
        )
        do {
            if groupGeneration > 0 && mlsClient.loadPendingGenerationJoin(cid: cid.rawValue) == nil {
                guard let groupId else {
                    throw ClientError.Unexpected(
                        "Generation-aware external join requires authoritative GroupId."
                    )
                }
                try mlsClient.savePendingGenerationJoin(
                    .init(
                        cid: cid.rawValue,
                        generation: UInt64(groupGeneration),
                        groupId: groupId,
                        epoch: targetEpoch,
                        status: "external_join_prepared",
                        operationId: nil
                    )
                )
            }
            try durableInboxStore.prepareLocalJoinReceipt(
                accountId: accountId,
                scopeCid: cid.rawValue,
                epoch: targetEpoch,
                commitHash: commitHash,
                requestDeviceId: requestDeviceId
            )
        } catch {
            try? clearPendingCommit(in: cid)
            mlsClient.removePendingGenerationJoin(cid: cid.rawValue)
            trace.failure(
                stage: "join_receipt_prepare_failed",
                source: "external_join",
                error: error,
                receipt: joinReceiptTraceStatus(for: cid.rawValue),
                groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
                localEpoch: targetEpoch
            )
            completion(error)
            return
        }
        trace.info(
            stage: "join_receipt_prepared",
            source: "external_join",
            result: "external_commit_request_required",
            receipt: "prepared",
            groupLoaded: true,
            localEpoch: targetEpoch
        )
        let body = ExternalJoinRequestBody(commit: externalJoinResult.commit,
                                           epoch: Int(targetEpoch),
                                           groupGeneration: groupGeneration,
                                           groupId: groupId,
                                           projectId: cid.projectId)
        apiClient.request(endpoint: .externalJoin(cid: cid, body: body)) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success:
                trace.info(
                    stage: "external_commit_accepted",
                    source: "external_join",
                    result: "accepted",
                    receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                    localEpoch: targetEpoch
                )
                do {
                    try durableInboxStore.markLocalJoinServerAccepted(
                        accountId: accountId,
                        scopeCid: cid.rawValue
                    )
                    let (groupInfo, epoch) = try performMlsMutation(cidString: cid.rawValue) {
                        try self.mlsClient.mergePendingCommit(in: cid)
                        let group = externalJoinResult.group
                        return (try self.mlsClient.exportGroupInfo(of: group), group.epoch())
                    }
                    try durableInboxStore.markLocalJoinMerged(
                        accountId: accountId,
                        scopeCid: cid.rawValue,
                        firstDecryptableEpoch: epoch
                    )
                    if groupGeneration > 0 || self.mlsClient.loadPendingGenerationJoin(cid: cid.rawValue)?.providerPath != nil {
                        let pending = self.mlsClient.loadPendingGenerationJoin(cid: cid.rawValue)
                        try self.mlsClient.saveGenerationMarker(
                            .init(
                                cid: cid.rawValue,
                                generation: UInt64(groupGeneration),
                                groupId: groupId ?? externalJoinResult.group.groupId(),
                                epoch: epoch,
                                status: "active",
                                operationId: nil,
                                providerPath: pending?.providerPath
                            )
                        )
                        self.mlsClient.removePendingGenerationJoin(cid: cid.rawValue)
                    }
                    try durableInboxStore.clearNoMatchingKeyPackageJoinPrerequisite(
                        accountId: accountId,
                        scopeCid: cid.rawValue
                    )
                    normalizeHistoricalApplications(cid: cid)
                    trace.info(
                        stage: "external_commit_merged",
                        source: "external_join",
                        result: "group_info_publish_required",
                        receipt: "merged",
                        groupLoaded: true,
                        localEpoch: epoch
                    )
                    uploadGroupInfo(in: cid, groupInfo: groupInfo, epoch: Int(epoch)) { error in
                        if let error {
                            trace.failure(
                                stage: "group_info_publish_failed",
                                source: "external_join",
                                error: error,
                                receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                                groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                                localEpoch: epoch
                            )
                        } else {
                            trace.info(
                                stage: "group_info_published",
                                source: "external_join",
                                result: "post_sync_required",
                                receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                                groupLoaded: true,
                                localEpoch: epoch
                            )
                        }
                        completion(error)
                    }
                } catch (let error) {
                    trace.failure(
                        stage: "external_commit_merge_failed",
                        source: "external_join",
                        error: error,
                        receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                        groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                        localEpoch: targetEpoch
                    )
                    completion(error)
                }
            case .failure(let error):
                try? clearPendingCommit(in: cid)
                trace.failure(
                    stage: "external_commit_request_failed",
                    source: "external_join",
                    error: error,
                    receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                    localEpoch: targetEpoch
                )
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

    func groupGeneration(for cid: ChannelId) -> Int {
        let effectiveCid = mlsGroupCid(for: cid)
        return Int(mlsClient.loadGenerationMarker(cid: effectiveCid.rawValue)?.generation ?? 0)
    }

    func encryptedMessage(
        _ message: E2ePayload,
        in cid: ChannelId,
        trace: E2eeSendTrace.Context? = nil
    ) throws -> ([UInt8], Int) {
        try encryptedMessage(
            message,
            in: cid,
            authenticatedAAD: nil,
            trace: trace
        )
    }

    func encryptedMessage(
        _ message: E2ePayload,
        aad: E2eeMessageAADV1,
        in cid: ChannelId,
        trace: E2eeSendTrace.Context? = nil
    ) throws -> ([UInt8], Int) {
        try encryptedMessage(
            message,
            in: cid,
            authenticatedAAD: aad.encoded(),
            trace: trace
        )
    }

    private func encryptedMessage(
        _ message: E2ePayload,
        in cid: ChannelId,
        authenticatedAAD: Data?,
        trace: E2eeSendTrace.Context?
    ) throws -> ([UInt8], Int) {
        // Resolve the group cid and encode the payload up front (no MLS state touched),
        // then perform the actual MLS encryption on the shared serial queue so it never
        // runs concurrently with a decrypt/commit on the same group (correctness) and
        // never contends with them on the MLS SQLite store (latency). The operation does
        // no Core Data work, so blocking the caller via `waitUntilFinished` is deadlock-safe.
        let groupCid = mlsGroupCid(for: cid).rawValue
        let scopedTrace = trace?.scoped(to: groupCid)
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            scopedTrace?.failure(stage: "payload_encode_failed", error: error)
            throw error
        }
        scopedTrace?.info(stage: "payload_encoded", payloadBytes: data.count)

        var result: Result<([UInt8], Int), Error>?
        let enqueuedAt = E2eeSendTrace.nowNanoseconds()
        scopedTrace?.info(stage: "mls_queue_enqueued", payloadBytes: data.count)
        let op = BlockOperation { [weak self] in
            guard let self else {
                let error = ClientError.MlsNoProviderError()
                scopedTrace?.failure(stage: "mls_queue_owner_missing", error: error)
                result = .failure(error)
                return
            }
            scopedTrace?.info(
                stage: "mls_queue_started",
                queueWaitMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: enqueuedAt)
            )
            let loadStartedAt = E2eeSendTrace.nowNanoseconds()
            scopedTrace?.info(stage: "mls_group_load_started")
            let group: Group
            do {
                group = try self.mlsClient.loadGroup(with: groupCid)
            } catch {
                log.debug(
                    "[E2ESendSafety] send_safety=blocked sync_health=\(self.syncHealth(for: groupCid)) reason=group_load",
                    subsystems: .mls
                )
                scopedTrace?.failure(
                    stage: "mls_group_load_failed",
                    error: error,
                    operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: loadStartedAt)
                )
                result = .failure(error)
                return
            }
            let epoch = UInt64(group.epoch())
            guard self.canEncrypt(in: group, scopeCid: groupCid) else {
                let error = ClientError.E2eeChannelNotReady(
                    cid: groupCid,
                    state: self.readiness(for: cid)
                )
                scopedTrace?.failure(stage: "send_safety_blocked", error: error)
                result = .failure(error)
                return
            }
            log.debug(
                "[E2ESendSafety] send_safety=allowed sync_health=\(self.syncHealth(for: groupCid))",
                subsystems: .mls
            )
            scopedTrace?.info(
                stage: "mls_group_load_succeeded",
                epoch: epoch,
                operationMilliseconds: E2eeSendTrace.elapsedMilliseconds(since: loadStartedAt)
            )
            do {
                let encryptedData: Data
                if let authenticatedAAD {
                    encryptedData = try self.mlsClient.encrypt(
                        inputData: data,
                        aad: authenticatedAAD,
                        in: group,
                        trace: scopedTrace
                    )
                } else {
                    encryptedData = try self.mlsClient.encrypt(
                        inputData: data,
                        in: group,
                        trace: scopedTrace
                    )
                }
                scopedTrace?.info(
                    stage: "encrypt_succeeded",
                    epoch: epoch,
                    ciphertextBytes: encryptedData.count
                )
                result = .success((encryptedData.uint8Array, Int(epoch)))
            } catch {
                scopedTrace?.failure(stage: "encrypt_failed", error: error)
                result = .failure(error)
            }
        }
        // Sends run ahead of background sync so they aren't blocked by a sync backlog.
        op.queuePriority = .high
        let scheduledOperation = enqueueGroupOperation(op, cidString: groupCid)
        scheduledOperation.waitUntilFinished()
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            let error = ClientError.Unexpected("Encryption did not complete.")
            scopedTrace?.failure(stage: "mls_queue_completed_without_result", error: error)
            throw error
        }
    }

    /// Send safety intentionally differs from public readiness: a merged receipt proves that
    /// this exact local provider has the server-accepted external commit, while post-sync is
    /// still allowed to reconcile metadata and historical ciphertext in the background.
    private func canEncrypt(in group: Group, scopeCid: String) -> Bool {
        durableApplyLock.lock()
        let protocolBlocked = blockedDurableScopes.contains(scopeCid)
        durableApplyLock.unlock()
        guard !protocolBlocked,
              let accountId = mlsClient.userId,
              let deviceId = mlsClient.currentDeviceId else {
            log.debug(
                "[E2ESendSafety] send_safety=blocked sync_health=protocol_blocked",
                subsystems: .mls
            )
            return false
        }
        do {
            guard let receipt = try durableInboxStore.localJoinReceiptProof(
                accountId: accountId,
                scopeCid: scopeCid
            ) else { return true } // restored group, no unresolved external join
            let safe = receipt.status == .merged &&
                receipt.requestDeviceId == deviceId &&
                receipt.epoch == UInt64(group.epoch())
            if !safe {
                log.debug(
                    "[E2ESendSafety] send_safety=blocked sync_health=repairing",
                    subsystems: .mls
                )
            }
            return safe
        } catch {
            log.error(
                "[E2ESendSafety] send_safety=blocked receipt_read_failed "
                    + PrivacySafeLogMetadata.errorFields(error),
                subsystems: .mls
            )
            return false
        }
    }

    private func syncHealth(for scopeCid: String) -> String {
        durableApplyLock.lock()
        let protocolBlocked = blockedDurableScopes.contains(scopeCid)
        durableApplyLock.unlock()
        if protocolBlocked { return "protocol_blocked" }
        guard let accountId = mlsClient.userId else { return "repairing" }
        if (try? durableInboxStore.localJoinReceiptProof(
            accountId: accountId,
            scopeCid: scopeCid
        )) != nil {
            return "repairing"
        }
        return "healthy"
    }
    
    func mergePendingCommit(in cid: ChannelId) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            try self.mlsClient.mergePendingCommit(in: cid)
        }
    }
    
    func clearPendingCommit(in cid: ChannelId) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            try self.mlsClient.clearPendingCommit(in: cid)
        }
    }
    
    func commitPendingProposal(in cid: ChannelId) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            try self.mlsClient.commitPendingProposal(in: cid)
        }
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
    private func shouldSkipWelcome(cid cidString: String, incomingGeneration: Int = 0) -> Bool {
        if incomingGeneration > 0 {
            let localGeneration = mlsClient.loadGenerationMarker(cid: cidString)?.generation ?? 0
            return localGeneration >= UInt64(incomingGeneration)
        }
        guard mlsClient.isGroupLoaded(cid: cidString) else {
            return false
        }
        return true
    }
    
    func clearPendingProposal(in cid: ChannelId) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            try self.mlsClient.clearPendingProposal(in: cid)
        }
    }
    
    public func reset() {
        loginTime = nil
        stopRuntimeOperations()
        do {
            try mlsClient.reset()
        } catch (let error) {
            log.error(
                "[MLS] state=runtime_release_failed \(PrivacySafeLogMetadata.errorFields(error))",
                subsystems: .mls
            )
        }
    }

    func purgeCurrentUserState() throws {
        let currentUserId = mlsClient.userId
        loginTime = nil
        stopRuntimeOperations()
        if let currentUserId {
            var removedCursors = mlsClient.userDefaults.dictionary(forKey: Self.removedCursorKey) ?? [:]
            removedCursors.removeValue(forKey: currentUserId)
            mlsClient.userDefaults.set(removedCursors, forKey: Self.removedCursorKey)
        }
        try performMlsMutation(cidStrings: ["__all_groups__"]) {
            try self.mlsClient.purgeCurrentUserData()
        }
    }

    private func stopRuntimeOperations() {
        abortSync()
        bootstrapQueue.reset()
        readinessLock.lock()
        readinessByCid.removeAll()
        readinessCallbacks.removeAll()
        readinessLock.unlock()
        mutationExecutor.cancelAllAndWait()
        durableApplyLock.lock()
        blockedDurableScopes.removeAll()
        enqueuedDurableEvents.removeAll()
        scheduledDurableDrains.removeAll()
        durableApplyLock.unlock()
    }
    
    public func deleteGroup(cid: String) throws {
        try performMlsMutation(cidString: cid) {
            try self.mlsClient.deleteGroup(cid: cid)
        }
        // Advance (do NOT clear) the cursor so a later re-add/re-invite won't replay the
        // old Welcome (already-consumed KeyPackage → NoMatchingKeyPackage). See
        // `advanceE2eSyncCursor`.
        advanceE2eSyncCursor(for: cid)
    }

    public func deleteGroups(cids: [String]) throws {
        try performMlsMutation(cidStrings: Set(cids)) {
            for cid in cids {
                if self.mlsClient.isGroupLoaded(cid: cid) {
                    try self.mlsClient.deleteGroup(cid: cid)
                }
                self.advanceE2eSyncCursor(for: cid)
            }
        }
    }

    // MARK: - Decryption

    /// The single decryption gate for all message sources (WebSocket, API, NSE).
    ///
    /// Enqueues work onto `MlsMutationExecutor` so MLS `processMessage` is
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
        receiveSource: E2eeAttachmentReceiveSource = .directDecrypt,
        expectedEnvelope: E2eeReceivedMessageEnvelope? = nil,
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
                receiveSource: receiveSource,
                expectedEnvelope: expectedEnvelope,
                completion: completion
            )
        }
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: mlsGroupCid(for: cid).rawValue)
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
            if let cid = message.cid {
                e2eeAttachmentReceiveCoordinator.hydratePreviews(
                    payload: cached,
                    messageId: message.id,
                    cid: cid,
                    source: .cachedModel
                )
            }
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
        let currentGeneration = groupGeneration(for: cid)
        guard (message.mlsGroupGeneration ?? 0) == currentGeneration else {
            completion(.failure(ClientError.Unexpected("Message belongs to an inactive MLS group generation.")))
            return
        }

        decryptMessagePayload(
            messageId: message.id,
            encryptedData: encryptedData,
            cid: cid,
            receiveSource: .directDecrypt
        ) { result in
            switch result {
            case .success(let payload):
                var updated = message
                updated.text = payload.text
                updated.stickerUrl = payload.stickerUrl
                updated.decryptedMessage = payload
                completion(.success(updated))
            case .failure(let error):
                completion(.failure(error))
                log.error(
                    "[MLS] state=message_decrypt_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
            }
        }
    }
}
