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
    private struct Entry { let cid: ChannelId; let ticket: UUID }
    private let lock = NSLock()
    private var pending: [Entry] = [], urgent: [Entry] = []
    private var head = 0, urgentHead = 0, priorityStreak = 0
    private var admitted: [String: UUID] = [:]
    private var promoted = Set<UUID>()
    private var deferredSync = Set<String>()
    private var active: Entry?
    private var isRunning = false
    private var prepared: [Entry] = []
    private var preparedHead = 0
    private var preparedIds = Set<String>()
    private var pointReads = Set<String>()
    private var preparedPoints: [Entry] = []
    private var preparedPointHead = 0
    private var syncing = Set<String>()
    private var fullSyncRequested = false

    func enqueue(_ cid: ChannelId) -> Bool { enqueue([cid]) }

    func enqueue(_ cids: [ChannelId]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for cid in cids where admitted[cid.rawValue] == nil {
            let entry = Entry(cid: cid, ticket: UUID())
            admitted[cid.rawValue] = entry.ticket; pending.append(entry)
        }
        return startIfNeeded()
    }

    /// Promote queued scope admission, never the active operation. Duplicate opens coalesce.
    func enqueuePriority(_ cid: ChannelId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let added = pointReads.insert(cid.rawValue).inserted
        if preparedIds.contains(cid.rawValue) || syncing.contains(cid.rawValue) {
            if added, preparedIds.contains(cid.rawValue), let ticket = admitted[cid.rawValue] {
                preparedPoints.append(Entry(cid: cid, ticket: ticket))
            }
            return startIfNeeded()
        }
        if admitted[cid.rawValue] == nil {
            let entry = Entry(cid: cid, ticket: UUID())
            admitted[cid.rawValue] = entry.ticket; pending.append(entry)
        }
        if active?.cid != cid, let ticket = admitted[cid.rawValue], promoted.insert(ticket).inserted {
            urgent.append(Entry(cid: cid, ticket: ticket))
        }
        return startIfNeeded()
    }

    private func startIfNeeded() -> Bool {
        guard !isRunning, head < pending.count || urgentHead < urgent.count || preparedHead < prepared.count else { return false }
        isRunning = true; return true
    }

    func dequeue() -> ChannelId? {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, syncing.isEmpty else { return nil }
        // Every entry is skipped/dequeued once. Ticket identity fences old promoted slots
        // if the same scope is legitimately re-enqueued after an earlier completion.
        while head < pending.count {
            let entry = pending[head]
            if admitted[entry.cid.rawValue] == entry.ticket && !promoted.contains(entry.ticket) { break }
            head += 1
        }
        while urgentHead < urgent.count {
            let entry = urgent[urgentHead]
            if admitted[entry.cid.rawValue] == entry.ticket && promoted.contains(entry.ticket) { break }
            urgentHead += 1
        }
        let next: Entry
        if urgentHead < urgent.count && (priorityStreak < 2 || head == pending.count) {
            next = urgent[urgentHead]; urgentHead += 1; promoted.remove(next.ticket); priorityStreak += 1
        } else if head < pending.count {
            next = pending[head]; head += 1; priorityStreak = 0
        } else {
            pending.removeAll(keepingCapacity: true); urgent.removeAll(keepingCapacity: true)
            head = 0; urgentHead = 0; priorityStreak = 0; active = nil; isRunning = preparedHead < prepared.count
            return nil
        }
        active = next; return next.cid
    }

    func finish(_ cid: ChannelId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active?.cid == cid { admitted.removeValue(forKey: cid.rawValue); active = nil }
        pointReads.remove(cid.rawValue)
        return deferredSync.remove(cid.rawValue) != nil
    }

    /// A completed join is not messaging Ready. Keep the scope admitted until batch catch-up.
    func prepareForBatchSync(_ cid: ChannelId) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = active, entry.cid == cid else { return }
        active = nil
        if preparedIds.insert(cid.rawValue).inserted {
            prepared.append(entry)
            if pointReads.contains(cid.rawValue) { preparedPoints.append(entry) }
        }
    }

    /// The normal path drains joins first; an explicit open may request one point read.
    func takeSyncBatch(limit: Int = Int.max, pointOnly: Bool = false) -> [ChannelId] {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, syncing.isEmpty else { return [] }
        var result: [ChannelId] = []
        if pointOnly {
            guard priorityStreak < 2 else { return [] }
            while preparedPointHead < preparedPoints.count {
                let entry = preparedPoints[preparedPointHead]; preparedPointHead += 1
                if admitted[entry.cid.rawValue] == entry.ticket && pointReads.contains(entry.cid.rawValue) &&
                    preparedIds.remove(entry.cid.rawValue) != nil {
                    result = [entry.cid]; priorityStreak += 1; break
                }
            }
            if preparedPointHead == preparedPoints.count { preparedPoints.removeAll(keepingCapacity: true); preparedPointHead = 0 }
        } else {
            while preparedHead < prepared.count && result.count < limit {
                let entry = prepared[preparedHead]; preparedHead += 1
                if preparedIds.remove(entry.cid.rawValue) != nil { result.append(entry.cid) }
            }
            if preparedHead == prepared.count { prepared.removeAll(keepingCapacity: true); preparedHead = 0 }
        }
        syncing.formUnion(result.map(\.rawValue))
        for cid in result { deferredSync.remove(cid.rawValue) }
        return result
    }

    func finishSyncBatch(_ cids: [ChannelId]) {
        lock.lock(); defer { lock.unlock() }
        for cid in cids {
            syncing.remove(cid.rawValue); pointReads.remove(cid.rawValue)
            if deferredSync.remove(cid.rawValue) != nil, let ticket = admitted[cid.rawValue] {
                if preparedIds.insert(cid.rawValue).inserted { prepared.append(Entry(cid: cid, ticket: ticket)) }
            } else { admitted.removeValue(forKey: cid.rawValue) }
        }
    }

    func deferSyncIfAdmitted(_ cid: ChannelId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard admitted[cid.rawValue] != nil else { return false }
        deferredSync.insert(cid.rawValue); return true
    }

    func contains(_ cid: ChannelId) -> Bool {
        lock.lock(); defer { lock.unlock() }; return admitted[cid.rawValue] != nil
    }

    func deferFullSyncIfAdmitted(inventoryLoading: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inventoryLoading || !admitted.isEmpty else { return false }
        fullSyncRequested = true
        return true
    }

    /// Called only after dequeue has drained join preparation, before claiming transport.
    func takeFullSyncRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, syncing.isEmpty, fullSyncRequested else { return false }
        fullSyncRequested = false
        return true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(); urgent.removeAll(); head = 0; urgentHead = 0; priorityStreak = 0
        admitted.removeAll(); promoted.removeAll(); deferredSync.removeAll(); active = nil; isRunning = false
        prepared.removeAll(); preparedHead = 0; preparedIds.removeAll(); pointReads.removeAll(); syncing.removeAll()
        preparedPoints.removeAll(); preparedPointHead = 0
        fullSyncRequested = false
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

/// A value snapshot, not a second scheduler. Nested non-gated topics inherit membership;
/// isolated topics need the independently authorized, fully paged topic query.
enum E2eeSessionInventory {
    static func channels(roots: [ChannelPayload], topics: [ChannelPayload], userId: String, includingStandard: Bool = false) -> [String: String] {
        func eligible(_ row: ChannelPayload) -> Bool {
            guard row.channel.deletedAt == nil, row.channel.isClosedTopic != true,
                  let membership = row.membership, membership.userId == userId,
                  membership.isBanned != true, membership.isBlocked != true,
                  let role = membership.role else { return false }
            return [.owner, .admin, .moderator, .member].contains(role)
        }
        func scope(_ row: ChannelPayload) -> String {
            (row.channel.e2eeGroupId ?? (row.channel.gate == true ? row.channel.cid : row.channel.parentcid ?? row.channel.cid)).rawValue
        }
        var result: [String: String] = [:]
        for root in roots where eligible(root) {
            if includingStandard || root.channel.mlsEnabled { result[root.channel.cid.rawValue] = scope(root) }
            for topic in root.topics ?? [] where topic.channel.deletedAt == nil && topic.channel.isClosedTopic != true {
                // The full root payload contains all nested topics, but a parent's role
                // cannot grant admission to a topic with its own MLS scope.
                guard (includingStandard || root.channel.mlsEnabled), scope(topic) == scope(root) else { continue }
                if topic.membership != nil && !eligible(topic) { continue }
                result[topic.channel.cid.rawValue] = scope(topic)
            }
        }
        for topic in topics where eligible(topic) && (includingStandard || topic.channel.mlsEnabled) {
            result[topic.channel.cid.rawValue] = scope(topic)
        }
        return result
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
    /// A verified pre-join edit is retained as encrypted history, without replaying it.
    case preJoinEncryptedUpdate(generation: Int)
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
    var archiveRecovery: E2eeArchiveRecovery?
    private let historyPageLock = NSLock()
    private var historyPageSession = UUID()
    private var channelListPreviews: [String: (ChannelId, MessagePayload)] = [:]
    private var lastRequestedHistoryPage: (ChannelId, [E2eeArchiveWire])?
    // True = active, false = settled for this session; fingerprints only.
    private var historyPagesInFlight: [String: Bool] = [:]
    let sessionProgress = SessionSyncProgress()
    private var syncProgressTicket: SessionSyncProgress.Ticket?
    private var syncIncludesStandard = false
    private var standardSyncFinishing = false
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
    private var keyPackageRefillSchedule = MlsKeyPackageRefillSchedule()
    private var keyPackageRefillToken: UUID?
    private var keyPackagePipeline: MlsKeyPackagePipeline?
    private var keyPackageWake: DispatchWorkItem?
    private var welcomeBoundaryWakes = Set<String>() // protected by durableApplyLock
    
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
        var newerMembership = false
        database.viewContext.performAndWait {
            let channel = ChannelDTO.load(cid: cid, context: database.viewContext)
            joinedAt = channel?.mlsGroupJoinedAt?.bridgeDate
            if let member = channel?.membership, member.user.userId == mlsClient.userId {
                newerMembership = Self.hasNewerActiveMembership(
                    memberCreatedAt: member.memberCreatedAt?.bridgeDate,
                    isJoined: member.isJoined || member.channelRoleRaw == MemberRole.pending.rawValue,
                    removedAt: removedAt
                )
            }
        }
        // A fresh re-invite must protect its queued Welcome before a new MLS join anchor exists.
        if newerMembership { return true }
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
    // HTTP/job completion is not proof of a successful live catch-up. Protected by syncLock.
    private var unverifiedLiveSyncScopes: Set<String> = []
    private struct LiveSyncCoverage {
        let completedAt: TimeInterval
        let demand: UUID
        let marker: MlsClient.GroupGenerationMarker?
        let membershipDate: Date?
    }
    private struct ScopeSyncDemand {
        let id: UUID
        let protocolDigest: String?
    }
    // Causal indexes for HTTP coalescing only; never runtime messaging permission.
    // All three maps are protected by syncLock and retired with the session.
    private var liveSyncCoverage: [String: LiveSyncCoverage] = [:]
    private var scopeSyncDemand: [String: ScopeSyncDemand] = [:]
    private var successfulSyncDemand: [String: UUID] = [:]
    private var activeSyncMembershipDates: [String: Date] = [:]
    private var successfulSyncScopes: Set<String> = []
    private var pendingSyncReadinessScopes: Set<String> = []
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
    private let membershipRequestLock = NSLock()
    private var membershipRequestsInFlight: Set<String> = []
    private var membershipLastAttempt: [String: Date] = [:]
    var membershipMutationSender: ((MlsMembershipMutation, @escaping (Error?) -> Void) -> Void)?
    var membershipMutationStageHook: (String) throws -> Void = { _ in }

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
    private var dormantBootstrapScopes = Set<String>()
    private var bootstrapStartedAt: [String: TimeInterval] = [:]
    private var lastBootstrapConnectionId: String?
    private var activeBootstrapCid: String?
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
        if let encoder = apiClient.encoder as? DefaultRequestEncoder {
            encoder.mlsProofAuthorizer = MlsRequestProofAuthorizer(session: apiClient.session) { [weak self] in
                guard let self else { throw ClientError.MlsNoIdentityError() }
                return try self.performMlsMutation(cidString: "__identity__") {
                    guard let identity = self.mlsClient.identity, let user = self.mlsClient.userId,
                        let device = self.mlsClient.currentDeviceId else { throw ClientError.MlsNoIdentityError() }
                    let current: () throws -> Void = { [weak self] in
                        guard let self, self.mlsClient.userId == user, self.mlsClient.currentDeviceId == device,
                            self.mlsClient.identity === identity else { throw ClientError.Unexpected("MLS proof owner changed") }
                    }
                    return MlsRequestProofOwner(userId: user, deviceId: device, publicKey: identity.signaturePublicKey(),
                        assertCurrent: current,
                        registrationSignature: { device, project, issued in
                            try self.performMlsMutation(cidString: "__identity__") { try current(); return try identity.deviceRegistrationSignature(deviceId: device, projectId: project, issuedAt: issued) }
                        }, sign: { context in
                            try self.performMlsMutation(cidString: "__identity__") { try current(); return try identity.lorRequestSignature(contextJson: context) }
                        })
                }
            }
        }

        mlsClient.archiveCaptureHandler = { [weak self] cid, generation, group, role in
            guard let recovery = self?.archiveRecovery else { return }
            do { try recovery.capture(cid: cid, generation: generation, group: group, role: role) }
            catch { log.error("archive_upload stage=capture_failed reason=storage_or_key", subsystems: .mls) }
        }
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
                case .failure:
                    if self.observedScopeMembership(cid.rawValue) == false {
                        self.sessionProgress.excludeScope(cid.rawValue, owner: self.sessionProgress.owner)
                    }
                    self.setReadiness(.needsRetry, for: cid.rawValue)
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
            if let connection = event as? ConnectionStatusUpdated,
               case .connected(let id) = connection.webSocketConnectionState {
                resumeBootstrapAfterConnection(id)
            }
            reconcileKeyPackageInventory(reason: "manual", trigger: "connection")
        } else if let event = event as? HealthCheckEvent {
            handleHealthCheckEvent(event)
        } else if event is KeyPackageRefillEvent {
            reconcileKeyPackageInventory(reason: "manual", trigger: "demand")
        } else if let event = event as? MessageNewEvent {
            decryptNewMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? NotificationMessageNewEvent {
            decryptNewMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? MessageUpdatedEvent {
            decryptUpdatedMessageEventIfNeeded(message: event.message, cid: event.cid)
        } else if let event = event as? MLSEvent {
            handleMlsEvent(event)
        } else if let event = event as? GiPublicationRequestedEvent {
            reconcileGiPublication(cid: event.cid)
        } else if let event = event as? GroupInfoRefreshRequestedEvent {
            handleGroupInfoRefreshRequested(event)
        } else if let event = event as? GroupInfoUploadedEvent {
            handleGroupInfoUploaded(event)
        } else if let event = event as? MemberRemovedEvent {
            handleNotificationMemberRemoveEvent(event)
        } else if let event = event as? ChannelDeletedEvent {
            retireInventoryChannel(event.cid, topics: event.topicCids)
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
        }
    }
    
    private func handleNotificationInviteRejectedEvent(_ event: NotificationInviteRespondBackEvent) {
        // No protocol catch-up for another user's invitation response.
        // New membership admission is handled only by the acceptance path.
    }
    
    private func handleNotificationInviteSkippedEvent(_ event: NotificationInviteRespondBackEvent) {
        // No protocol catch-up for another user's invitation response.
        // New membership admission is handled only by the acceptance path.
    }
    
    private func handleNotificationMemberRemoveEvent(_ event: MemberRemovedEvent) {
        if isObsoleteMemberRemoval(cid: event.cid, userId: event.member.userId, removedAt: event.createdAt) {
            log.debug("[MLS] state=member_removed_ignored reason=newer_membership source=websocket", subsystems: .mls)
            return
        }
        let targetUserId = event.member.userId
        let cidString = event.cid.rawValue

        // Current user was removed (or self-left) → delete local MLS group.
        if targetUserId == mlsClient.userId {
            retireInventoryChannel(event.cid, topics: event.topicCids)
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

        // The next explicit membership mutation bundles this pending ghost.
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
        let assertOwner = captureHistorySessionOwner()
        let groupCid = mlsGroupCid(for: mlsEvent.cid)
        let op = BlockOperation { [weak self] in
            guard let self, (try? assertOwner()) != nil else { return }
            if mlsProtocol.user.id == mlsClient.userId,
               let deviceId = mlsProtocol.deviceId, deviceId == mlsClient.currentDeviceId,
               mlsClient.loadPendingGenerationJoin(cid: groupCid.rawValue) == nil,
               (try? self.hasNoPendingMembershipMutation(groupCid)) == true,
               let marker = mlsClient.loadGenerationMarker(cid: groupCid.rawValue), marker.status == "active",
               marker.generation == UInt64(exactly: mlsProtocol.groupGeneration),
               (marker.generation == 0 || marker.groupId == mlsProtocol.groupId.map { Data($0) }),
               let epoch = try? self.mlsClient.loadGroup(with: groupCid.rawValue).epoch(),
               let eventEpoch = UInt64(exactly: mlsProtocol.epoch), epoch >= eventEpoch {
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
            self.durableApplyLock.lock()
            let isBlocked = self.blockedDurableScopes.contains(cid)
            self.durableApplyLock.unlock()
            guard !isBlocked else {
                // A newly delivered canonical predecessor can unblock a local gap. Retry
                // the same durable ordered prefix once for new input, never HTTP polling.
                if let envelope = mlsEvent.protocolEnvelope, let account = self.mlsClient.userId {
                    do {
                        _ = try self.durableInboxStore.persistPage(accountId: account, scopeCid: groupCid.rawValue,
                            events: [envelope], hasMore: false, nextCursor: nil)
                        self.scheduleDurableDrain(cid: groupCid, cidString: groupCid.rawValue, resetProtocolBlock: true)
                    } catch { self.blockDurableScope(groupCid.rawValue, eventId: envelope.eventId, error: error) }
                }
                trace.info(
                    stage: "protocol_deferred",
                    source: "websocket",
                    protocolType: mlsProtocol.type.rawValue,
                    result: "pending",
                    reason: "durable_repair",
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid),
                    eventEpoch: mlsProtocol.epoch
                )
                log.error("[MLS] state=realtime_protocol_blocked reason=durable_repair", subsystems: .mls)
                return
            }
            do {
                switch mlsEvent.mlsProtocol.type {
                case .commit, .externalCommit:
                    // Legacy unbound notifications are hints only. They must not poison
                    // the canonical outbox envelope that can arrive from the other room.
                    guard mlsEvent.protocolEnvelope != nil else { return }
                    try self.applyRealtimeCommit(mlsEvent, scope: groupCid)
                case .welcome:
                    if mlsProtocol.groupGeneration > 0 {
                        guard let envelope = mlsEvent.protocolEnvelope, let account = self.mlsClient.userId else {
                            throw E2eeSyncApplyError.invalidCommit(reason: "canonical realtime Welcome envelope missing")
                        }
                        _ = try self.durableInboxStore.persistPage(accountId: account, scopeCid: groupCid.rawValue,
                            events: [envelope], hasMore: false, nextCursor: nil)
                        self.scheduleDurableDrain(cid: groupCid, cidString: groupCid.rawValue)
                        return
                    }
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
                    throw E2eeSyncApplyError.invalidCommit(reason: "standalone proposal is reserved")
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
                self.blockDurableScope(groupCid.rawValue, eventId: mlsEvent.protocolEnvelope?.eventId, error: error)

            }
        }
        // Realtime protocol messages unblock decryption — prioritise them over bulk sync.
        // Chained per channel so commits/welcomes advance the epoch in arrival order and never
        // overtake an in-flight sync op for the same group (see `enqueueGroupOperation`).
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: groupCid.rawValue)
    }

    private func hasNoPendingMembershipMutation(_ cid: ChannelId) throws -> Bool {
        try mlsClient.membershipMutationStore().load(cid: cid.rawValue) == nil
    }

    private func applyRealtimeCommit(_ event: MLSEvent, scope: ChannelId) throws {
        guard let account = mlsClient.userId, let envelope = event.protocolEnvelope,
              case .protocol(let data) = envelope.event,
              let targetEpoch = UInt64(exactly: data.epoch), targetEpoch > 0 else {
            throw E2eeSyncApplyError.invalidCommit(reason: "canonical realtime Commit envelope missing")
        }
        guard let generation = UInt64(exactly: data.groupGeneration) else {
            throw E2eeSyncApplyError.invalidCommit(reason: "realtime Commit generation invalid")
        }
        let marker = mlsClient.loadGenerationMarker(cid: scope.rawValue)
        let localGeneration = marker?.generation ?? 0
        if generation < localGeneration { return }
        let group = generation == localGeneration ? try? mlsClient.loadGroup(with: scope.rawValue) : nil
        // Ignore an older notification without making a history/cursor claim or adding work.
        if let group, group.epoch() > targetEpoch { return }
        _ = try durableInboxStore.persistPage(accountId: account, scopeCid: scope.rawValue,
            events: [envelope], hasMore: false, nextCursor: nil)
        // First-login admission and retained candidates already have an owner. Preserve the
        // event while that owner obtains/activates a group; no second join or sync starts here.
        guard generation == localGeneration, group != nil,
              mlsClient.loadPendingGenerationJoin(cid: scope.rawValue) == nil else { return }
        guard generation == 0 || marker?.groupId == data.groupId.map({ Data($0) }) else {
            throw E2eeSyncApplyError.invalidCommit(reason: "realtime Commit generation identity mismatch")
        }
        if let first = try durableInboxStore.loadPendingPrefix(accountId: account, scopeCid: scope.rawValue, limit: 1).first,
           first.eventId != envelope.eventId {
            scheduleDurableDrain(cid: scope, cidString: scope.rawValue)
            return
        }
        _ = try processSingleE2eSyncEvent(envelope, accountId: account, cid: scope, cidString: scope.rawValue)
        try durableInboxStore.markRecoveredCommitApplied(accountId: account, scopeCid: scope.rawValue,
            eventId: envelope.eventId)
        reDecryptPendingMessages(in: scope)
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

    func archiveGeneration(for cid: String) throws -> UInt64 {
        try performMlsMutation(cidString: cid) { self.mlsClient.loadGenerationMarker(cid: cid)?.generation ?? 0 }
    }

    func captureHistorySessionOwner() -> () throws -> Void {
        historyPageLock.lock(); let session = historyPageSession; historyPageLock.unlock()
        let user = mlsClient.userId, device = mlsClient.currentDeviceId
        return { [weak self] in
            guard let self, user != nil, self.mlsClient.userId == user, self.mlsClient.currentDeviceId == device else { throw E2eeArchiveError.sessionEnded }
            self.historyPageLock.lock(); let current = self.historyPageSession; self.historyPageLock.unlock()
            guard current == session else { throw E2eeArchiveError.sessionEnded }
        }
    }

    /// Metadata owns this demand. Rendering stays cache-only and never calls bootstrap.
    func requestChannelListPreviews(_ channels: [ChannelPayload]) {
        historyPageLock.lock(); let session = historyPageSession; historyPageLock.unlock()
        let owner = captureHistorySessionOwner()
        guard (try? owner()) != nil else { return }
        historyPageLock.lock()
        guard historyPageSession == session else { historyPageLock.unlock(); return }
        let previews = E2eeChannelListPreview.select(channels,
            retaining: channelListPreviews.values.map { (cid: $0.0, message: $0.1) })
        // Retain only five recent heads across metadata pages; disposable on logout.
        channelListPreviews = Dictionary(uniqueKeysWithValues: previews.map { ($0.cid.rawValue, ($0.cid, $0.message)) })
        historyPageLock.unlock()
        // Membership in this authoritative payload permits an exact archive page.
        // Its independent provider does not depend on the live MLS Ready barrier.
        // A fresh metadata observation may retry a settled partial head; in-flight
        // admission still coalesces the same envelope.
        for preview in previews {
            requestHistoryPage(messages: [preview.message], cid: preview.cid, pageOwner: owner, retry: true)
        }
    }

    private func restoreChannelListPreviews(scope: String? = nil) {
        let owner = captureHistorySessionOwner()
        historyPageLock.lock()
        let snapshot = Array(channelListPreviews.values)
        historyPageLock.unlock()
        let pending = snapshot.filter { scope == nil || mlsGroupCid(for: $0.0).rawValue == scope }
        for (cid, message) in pending { requestHistoryPage(messages: [message], cid: cid, pageOwner: owner) }
    }

    func requestHistoryPage(messages: [MessagePayload], cid: ChannelId, pageOwner: (() throws -> Void)? = nil, retry: Bool = false) {
        do { try pageOwner?() } catch { return }
        guard messages.count <= 50 else { return }
        var missing = messages
        e2eReadContext.performAndWait {
            missing = messages.filter { message in
                guard let bytes = message.encryptedData,
                      let row = MessageDTO.load(id: message.id, context: e2eReadContext),
                      row.cid == cid.rawValue, row.encryptedData == Data(bytes),
                      let cached = row.decryptedMessage,
                      cached.ciphertextHash == Data(SHA256.hash(data: Data(bytes))),
                      (try? cached.asPayload()) != nil else { return true }
                return false
            }
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let page: [E2eeArchiveWire] = missing.compactMap { message in
            guard message.hasAuthoritativeGroupGeneration, message.groupGeneration >= 0,
                  let epoch = message.mlsEpoch, epoch >= 0, let bytes = message.encryptedData, !bytes.isEmpty,
                  let scope = message.historicalScopeCid ?? (cid.type.rawValue == "topic" ? nil : cid.rawValue) else { return nil }
            var raw: [String: E2eeArchiveWire] = ["cid": .string(cid.rawValue), "e2ee_group_id": .string(scope), "message_id": .string(message.id),
                "mls_ciphertext": .bytes(Data(bytes)), "mls_epoch": .uint(UInt64(epoch)), "group_generation": .uint(UInt64(message.groupGeneration)),
                "created_at": .string(formatter.string(from: message.createdAt)), "updated_at": .string(formatter.string(from: message.updatedAt)),
                "user_id": .string(message.user.id), "user": .object(["id": .string(message.user.id)]), "type": .string(message.type.rawValue)]
            if let parent = message.parentId { raw["parent_id"] = .string(parent) }
            if let quote = message.quotedMessageId { raw["quoted_message_id"] = .string(quote) }
            return .object(raw)
        }
        guard !page.isEmpty else { return }
        scheduleHistoryPage(cid: cid, page: page, retry: retry, pageOwner: pageOwner)
    }

    func retryRequestedHistoryPage(afterUnlock: Bool = false) {
        historyPageLock.lock()
        if afterUnlock { historyPagesInFlight = historyPagesInFlight.filter { $0.value } }
        let requested = lastRequestedHistoryPage; historyPageLock.unlock()
        if let (cid, page) = requested { scheduleHistoryPage(cid: cid, page: page, retry: true) }
        if afterUnlock { restoreChannelListPreviews() }
    }

    private func scheduleHistoryPage(cid: ChannelId, page: [E2eeArchiveWire], retry: Bool = false, pageOwner: (() throws -> Void)? = nil) {
        do { try pageOwner?() } catch { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(E2eeArchiveWire.array(page)), encoded.count <= 16 * 1024 * 1024 else { return }
        let key = Data(SHA256.hash(data: encoded)).base64EncodedString()
        historyPageLock.lock()
        lastRequestedHistoryPage = (cid, page)
        if retry, historyPagesInFlight[key] == false { historyPagesInFlight.removeValue(forKey: key) }
        let admitted = historyPagesInFlight[key] == nil
        if admitted { historyPagesInFlight[key] = true }
        let requestSession = historyPageSession
        historyPageLock.unlock()
        guard admitted, let recovery = archiveRecovery else {
            if admitted { historyPageLock.lock(); historyPagesInFlight.removeValue(forKey: key); historyPageLock.unlock() }
            return
        }
        let sessionOwner = captureHistorySessionOwner()
        let assertOwner = { try sessionOwner(); try pageOwner?() }
        let progress = sessionProgress.begin("restoring_page")
        Task {
            var partial = false
            defer {
                self.historyPageLock.lock()
                if self.historyPageSession == requestSession {
                    self.historyPagesInFlight[key] = false
                    if self.historyPagesInFlight.count > 128 {
                        let retired = self.historyPagesInFlight.filter { !$0.value && $0.key != key }.keys
                        for old in retired.prefix(self.historyPagesInFlight.count - 128) { self.historyPagesInFlight.removeValue(forKey: old) }
                    }
                }
                self.historyPageLock.unlock()
                self.sessionProgress.end(progress, partial: partial, retry: { [weak self] in self?.retryRequestedHistoryPage() })
            }
            do {
                try assertOwner()
                let grouped = Dictionary(grouping: page) { $0["e2ee_group_id"].string ?? cid.rawValue }
                for (scope, messages) in grouped {
                    try assertOwner(); let result = try await recovery.restoreHistoryPage(cid: scope, messages: messages)
                    partial = partial || result.unavailable > 0 || result.requiresPin; try assertOwner()
                }
            } catch { partial = true; log.warning("archive_page stage=partial", subsystems: .mls) }
        }
    }

    func applyArchivedApplication(scopeCid: String, generation: UInt64, archive: Data, snapshot: Data, envelope: E2eeArchiveWire, historicalPage: Bool = false, pageOwner: (() throws -> Void)? = nil) throws {
        guard let messageId = envelope["message_id"].string, let routeCid = envelope["cid"].string ?? Optional(scopeCid),
              let ciphertext = envelope["mls_ciphertext"].bytes, envelope["group_generation"].number ?? 0 == generation,
              routeCid == scopeCid || envelope["parent_cid"].string == scopeCid || envelope["e2ee_group_id"].string == scopeCid else { throw E2eeArchiveError.invalidData }
        let assertOwner = pageOwner ?? captureHistorySessionOwner(); try assertOwner()
        let lockStarted=DispatchTime.now().uptimeNanoseconds
        let work = {
            E2eeArchiveCost.record("lock_wait","success",lockStarted)
            try assertOwner()
            let recovered: MlsArchivedApplicationMessage
            if historicalPage {
                let historical = Provider()
                let decoded = try decryptEpochArchiveV2(provider: historical, archive: archive, snapshot: snapshot,
                    ciphertext: ciphertext, allowOwnMessages: true, maxForwardDistance: 0)
                guard decoded.content.count <= 16 * 1024 * 1024 else { throw E2eeArchiveError.invalidData }
                recovered = MlsArchivedApplicationMessage(plaintext: decoded.content, payload: try JSONDecoder().decode(E2ePayload.self, from: decoded.content),
                    aad: decoded.aad, epoch: decoded.epoch, senderIndex: decoded.senderIndex, senderGeneration: decoded.generation, ownMessage: decoded.ownMessage)
            } else {
                guard UInt64(self.groupGeneration(for: try ChannelId(cid: scopeCid))) == generation else { throw E2eeArchiveError.generationChanged }
                recovered = try self.mlsClient.decryptArchivedApplication(cid: scopeCid, generation: generation,
                    archive: archive, snapshot: snapshot, ciphertext: ciphertext, allowOwnMessages: true)
            }
            guard recovered.epoch == envelope["mls_epoch"].number else { throw E2eeArchiveError.invalidData }
            let members = try JSONDecoder().decode(E2eeArchiveWire.self, from: snapshot)["members"].array
            guard members.contains(where: { $0["leaf_index"].number == UInt64(recovered.senderIndex) && $0["user_id"].string == (envelope["user_id"].string ?? envelope["user"]["id"].string) }) else { throw E2eeArchiveError.invalidData }
            let cid = try ChannelId(cid: routeCid)
            let payload = try E2eeArchiveMessageValidator.validate(recovered.payload, processedAAD: recovered.aad, messageId: messageId,
                cid: cid.rawValue, groupCid: scopeCid, expectedEnvelope: nil)
            var raw = envelope.dictionary
            raw["id"] = .string(messageId)
            raw["cid"] = .string(routeCid)
            if envelope["user"].dictionary.isEmpty, let sender = envelope["user_id"].string { raw["user"] = .object(["id": .string(sender)]) }
            raw["updated_at"] = envelope["updated_at"].string == nil ? envelope["created_at"] : envelope["updated_at"]
            raw["text"] = .string("")
            let message = try JSONDecoder.ermis.decode(MessagePayload.self, from: JSONEncoder().encode(E2eeArchiveWire.object(raw)))
            var published = false
            do {
                try self.database.writeAndWait { session in
                    try assertOwner()
                    guard session.canPublishArchivedCiphertext(messageId: messageId, ciphertext: ciphertext, cid: cid.rawValue) else { return }
                    if let current = session.message(id: messageId) {
                        if current.deletedAt != nil || current.isHardDeleted || current.type == "deleted" { return }
                        if current.encryptedData != ciphertext { return }
                    } else {
                        _ = try session.saveMessage(payload: message, for: cid, syncOwnReactions: false, cache: nil)
                    }
                    try session.saveMessageDecrypt(payload: payload, messageId: messageId, ciphertextHash: Data(SHA256.hash(data: ciphertext)))
                    let current = session.message(id: messageId)
                    current?.text = payload.text
                    current?.forwardCid = payload.authenticatedMetadata?.forwardCid
                    published = true
                }
            } catch { throw E2eeArchiveError.storageFailure }
            try assertOwner()
            guard published else { throw E2eeArchiveError.safeSkipped }
            self.e2eeAttachmentReceiveCoordinator.hydratePreviews(payload: payload, messageId: messageId, cid: cid, source: .scopeSync)
        }
        if historicalPage { try work() } else { try performMlsMutation(cidString: scopeCid, work) }
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

        let assertOwner = captureRetainedHistoryOwner()
        let scope = mlsGroupCid(for: cid).rawValue
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            do {
                try assertOwner()
                try self.receiveStoredRealtimeApplication(messageId: message.id, encryptedData: encryptedData,
                    cid: cid, assertOwner: assertOwner)
            } catch {
                // The intake transaction already retained exact ciphertext. A later Commit or
                // admission retries it locally; cache-only display never owns an offline read.
                log.error("[MLS] state=realtime_decrypt_failed action=retain_ciphertext "
                    + PrivacySafeLogMetadata.errorFields(error), subsystems: .mls)
            }
        }
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: scope)
    }

    /// Global WS receive owner, after MessageDTO commit, running on the serialized MLS writer.
    /// Does not manufacture a scope event/cursor or fetch offline history on a cache miss.
    private func receiveStoredRealtimeApplication(messageId: MessageId, encryptedData: Data,
        cid: ChannelId, assertOwner: () throws -> Void) throws {
        try assertOwner()
        let scope = mlsGroupCid(for: cid)
        guard !isScopeBlocked(scope.rawValue),
              mlsClient.loadPendingGenerationJoin(cid: scope.rawValue) == nil,
              !mlsClient.hasNonOperationalGroup(cid: scope.rawValue) else { return }
        var generation: Int64?, epoch: Int64?, createdAt: Date?
        e2eReadContext.performAndWait {
            guard let row = MessageDTO.load(id: messageId, context: e2eReadContext),
                  row.cid == cid.rawValue, row.encryptedData == encryptedData,
                  row.deletedAt == nil, !row.isHardDeleted, row.type != "deleted" else { return }
            generation = row.mlsGroupGeneration; epoch = row.mlsEpoch; createdAt = row.createdAt.bridgeDate
        }
        guard let generation, generation >= 0, UInt64(generation) == (mlsClient.loadGenerationMarker(cid: scope.rawValue)?.generation ?? 0),
              let epoch, epoch >= 0, let createdAt,
              let group = try? mlsClient.loadGroup(with: scope.rawValue), UInt64(epoch) <= group.epoch() else { return }
        let firstEpoch = firstDecryptableEpoch(for: scope)
        if let firstEpoch, epoch < firstEpoch { return }
        if let account = mlsClient.userId,
           let boundary = try durableInboxStore.localJoinBoundary(accountId: account, scopeCid: scope.rawValue),
           createdAt < boundary.createdAt { return }
        guard !hasLocalJoinReceipt(for: scope.rawValue) else { return }
        try assertOwner()
        // The plaintext-first native receive helper also closes a crash between decoded DB
        // persistence and provider save. A display cache alone must not skip that proof step.
        _ = try decryptMessagePayloadSyncThrowing(messageId: messageId, encryptedData: encryptedData,
            cid: cid, receiveSource: .websocket)
        try assertOwner()
    }

    static func shouldSkipRealtimeDecrypt(
        isSentByCurrentUser: Bool,
        hasCachedPlaintext: Bool
    ) -> Bool {
        isSentByCurrentUser && hasCachedPlaintext
    }
    
    private func decryptUpdatedMessageEventIfNeeded(message: ChatMessage, cid: ChannelId) {
        // Another device of the same account can edit this message. The only own echo
        // we may skip is one with plaintext bound to this exact canonical ciphertext.
        // Reuse the normal ordered scope gate; never consume the ratchet on the UI path.
        decryptNewMessageEventIfNeeded(message: message, cid: cid)
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
        receiveSource: E2eeAttachmentReceiveSource,
        expectedEnvelope: E2eeReceivedMessageEnvelope? = nil
    ) throws {
        if let cached = try boundDisplayPayload(messageId: messageId, encryptedData: encryptedData,
                                               expectedEnvelope: expectedEnvelope) {
            e2eeAttachmentReceiveCoordinator.hydratePreviews(payload: cached, messageId: messageId,
                cid: cid, source: receiveSource)
            return
        }
        if let own = try acceptedOwnCaptionEditPayload(messageId: messageId, ciphertext: encryptedData,
                                                       cid: cid, expectedEnvelope: expectedEnvelope) {
            try database.writeAndWait { session in
                try session.saveMessageDecrypt(payload: own, messageId: messageId,
                    ciphertextHash: Data(SHA256.hash(data: encryptedData)))
                session.message(id: messageId)?.text = own.text
            }
            e2eeAttachmentReceiveCoordinator.hydratePreviews(payload: own, messageId: messageId,
                cid: cid, source: receiveSource)
            return
        }
        _ = try decryptMessagePayloadSyncThrowing(messageId: messageId, encryptedData: encryptedData,
            cid: cid, receiveSource: receiveSource, expectedEnvelope: expectedEnvelope)
    }

    private func acceptedOwnCaptionEditPayload(messageId: MessageId, ciphertext: Data, cid: ChannelId,
        expectedEnvelope: E2eeReceivedMessageEnvelope?) throws -> E2ePayload? {
        let owner = try mlsClient.sendIntentOwner(), fence = try captureSendOwnerFence()
        guard let intent = try mlsClient.captionEditIntentStore().acceptedEdit(owner: owner,
                messageId: messageId, ciphertext: ciphertext) else { return nil }
        try fence()
        guard intent.cid == mlsGroupCid(for: cid).rawValue,
              intent.generation == UInt64(groupGeneration(for: cid)), intent.nativeSealed else {
            throw MlsSendIntentError.conflict
        }
        let binding = try mlsClient.applicationSendBinding(cid: intent.cid)
        guard binding.0 == intent.generation, binding.1 == intent.groupId, binding.2 == intent.providerId else {
            throw MlsSendIntentError.conflict
        }
        try fence()
        return try validatedPayload(JSONDecoder().decode(E2ePayload.self, from: intent.payload),
            processedAAD: intent.aad, messageId: messageId, cid: cid, expectedEnvelope: expectedEnvelope)
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
            try? self?.reDecryptUpdatedMessageSync(
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
        MlsIncomingTrace.record(.decodedCacheSaved, uuid: messageId, ciphertext: encryptedData)
        let diagnosticHash = ciphertextHash.map { String(format: "%02x", $0) }.joined()
        log.info("mls_application_readback uuid=\(messageId.lowercased()) cipher_sha256=\(diagnosticHash) result=committed", subsystems: .mls)
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
        _ payload: E2ePayload, processedAAD: Data, messageId: MessageId, cid: ChannelId,
        expectedEnvelope: E2eeReceivedMessageEnvelope?
    ) throws -> E2ePayload {
        try E2eeArchiveMessageValidator.validate(payload, processedAAD: processedAAD, messageId: messageId,
            cid: cid.rawValue, groupCid: mlsGroupCid(for: cid).rawValue, expectedEnvelope: expectedEnvelope)
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
        reconcileKeyPackageInventory(reason: "manual", trigger: "health")
    }

    private func reconcileKeyPackageInventory(reason: String, trigger: String) {
        guard let token = beginKeyPackageRefill() else { return }
        log.info("keypackage_refill phase=started trigger=\(trigger)", subsystems: .mls)
        let user = mlsClient.userId, device = mlsClient.currentDeviceId, origin = apiClient.encoder.baseURL
        // Preflight can fail before a private snapshot exists. Retry only for this same
        // semantic session; a later successful attempt still acquires the full owner fence.
        let sessionCurrent: () throws -> Void = { [weak self] in
            guard let self, self.mlsClient.userId == user, self.mlsClient.currentDeviceId == device,
                self.apiClient.encoder.baseURL == origin,
                self.keyPackageRefillStateQueue.sync(execute: { self.keyPackageRefillToken == token })
            else { throw ClientError.Unexpected("key_package_scope_changed") }
        }
        do {
            let snapshot = try performMlsMutation(cidString: "__identity__") { () -> (String, String, Identity, Provider, MlsKeyPackageWorkStore) in
                guard let user = self.mlsClient.userId, let device = self.mlsClient.currentDeviceId,
                    let identity = self.mlsClient.identity, let provider = self.mlsClient.provider else { throw ClientError.MlsNoIdentityError() }
                return (user, device, identity, provider, try self.mlsClient.keyPackageWorkStore(origin: self.apiClient.encoder.baseURL.absoluteString))
            }
            let current: () throws -> Void = { [weak self] in
                guard let self, self.mlsClient.userId == snapshot.0, self.mlsClient.currentDeviceId == snapshot.1,
                    self.mlsClient.identity === snapshot.2, self.mlsClient.provider === snapshot.3,
                    self.apiClient.encoder.baseURL == origin,
                    self.keyPackageRefillStateQueue.sync(execute: { self.keyPackageRefillToken == token }) else { throw ClientError.Unexpected("key_package_scope_changed") }
            }
            let pipeline = try MlsKeyPackagePipeline(api: apiClient, store: snapshot.4, assertOwner: current,
                probe: { [weak self] refs in
                    guard let self else { throw ClientError.MlsNoProviderError() }
                    return try self.performMlsMutation(cidString: "__identity__") { try current(); return try self.mlsClient.probeKeyPackageOwnership(refs) }
                }, providerId: { [weak self] in
                    guard let self else { throw ClientError.MlsNoProviderError() }
                    return try self.performMlsMutation(cidString: "__identity__") { try current(); return try self.mlsClient.keyPackageUploadProviderId() }
                }, generate: { [weak self] id, nativeProviderId, count in
                    guard let self else { throw ClientError.MlsNoProviderError() }
                    return try self.performMlsMutation(cidString: "__identity__") { try current(); return try self.mlsClient.prepareKeyPackageUpload(id: id, scope: snapshot.4.scope, nativeProviderId: nativeProviderId, count: count) }
                }, recover: { [weak self] id in
                    guard let self else { throw ClientError.MlsNoProviderError() }
                    return try self.performMlsMutation(cidString: "__identity__") { try current(); return try self.mlsClient.recoverKeyPackageUpload(id: id, scope: snapshot.4.scope) }
                }, completion: { [weak self] at in
                    self?.completeKeyPackageRefill(token: token, at: at, reason: reason, assertOwner: current)
                })
            keyPackageRefillStateQueue.sync { keyPackagePipeline = pipeline }
            pipeline.start(reason: reason)
        } catch {
            completeKeyPackageRefill(token: token, at: Date().timeIntervalSince1970 + 30,
                reason: reason, assertOwner: sessionCurrent)
            log.warning("[MLS] state=keypackage_refill_pending reason=private_or_storage_uncertain", subsystems: .mls)
        }
    }

    private func beginKeyPackageRefill() -> UUID? {
        keyPackageRefillStateQueue.sync {
            guard keyPackageRefillSchedule.begin(at: ProcessInfo.processInfo.systemUptime) else { return nil }
            keyPackageWake?.cancel()
            keyPackageWake = nil
            let token = UUID()
            keyPackageRefillToken = token
            return token
        }
    }

    private func completeKeyPackageRefill(token: UUID, at: TimeInterval, reason: String, assertOwner: @escaping () throws -> Void) {
        keyPackageRefillStateQueue.async {
            guard self.keyPackageRefillToken == token else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            self.keyPackageRefillSchedule.complete(at: uptime)
            self.keyPackagePipeline = nil
            self.keyPackageWake?.cancel()
            let delay = self.keyPackageRefillSchedule.wakeDelay(requestedAt: at,
                wallTime: Date().timeIntervalSince1970, uptime: uptime)
            let wake = DispatchWorkItem { [weak self] in
                do { try assertOwner(); self?.reconcileKeyPackageInventory(reason: reason, trigger: "continuation") } catch { }
            }
            self.keyPackageWake = wake
            log.info("keypackage_refill phase=deferred delay_ms=\(Int(delay * 1000))", subsystems: .mls)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: wake)
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
        var pendingJoinReceipt = false
        var joinProof: E2eeDurableInboxStore.LocalJoinReceiptProof?
        if let accountId = mlsClient.userId {
            do {
                if let durableCursor = try durableInboxStore.fetchCursor(
                    accountId: accountId,
                    scopeCid: cidString
                ) {
                    return durableCursor
                }
                joinProof = try durableInboxStore.localJoinReceiptProof(
                    accountId: accountId, scopeCid: cidString
                )
                pendingJoinReceipt = joinProof != nil
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
        // An optional canonical receipt anchor selects the FIRST fetch only.
        // It never advances a durable cursor or authorizes protocol application.
        if let proof = joinProof, proof.status == .merged,
           let owner = bootstrapOwnerStamp(),
           let bytes = try? mlsClient.readRecoveryCheckpoint(key: initialJoinSyncKey(cidString, owner: owner)),
           let hint = try? JSONDecoder.default.decode(InitialJoinSyncAnchor.self, from: bytes),
           hint.owner == owner, hint.cid == cidString, hint.commitHash == proof.commitHash,
           hint.epoch == proof.epoch, hint.deviceId == proof.requestDeviceId,
           hint.deviceId == mlsClient.currentDeviceId,
           hint.marker == mlsClient.loadGenerationMarker(cid: cidString),
           hint.cursor.eventId == Self.zeroEventId,
           let start = Self.parseRemovedAt(hint.cursor.createdAt)?.timeIntervalSince1970,
           start > 0, start <= Date().timeIntervalSince1970 + 300, start.rounded(.towardZero) == start {
            return hint.cursor
        }
        // A locally merged join still needs its exact canonical commit boundary.
        // The device join timestamp is written AFTER acceptance and can skip that
        // commit on a first sync. Use the already-authoritative membership anchor
        // only while that receipt remains; never rewind a durable/legacy cursor.
        if pendingJoinReceipt, let memberCreatedAt {
            return Self.cursor(fromMilliseconds: Int64(memberCreatedAt.timeIntervalSince1970 * 1000))
        }
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
        if bootstrapQueue.deferFullSyncIfAdmitted(inventoryLoading: sessionProgress.isInventoryBootstrapDeferred) {
            return
        }
        reconcilePendingGroupInfoRepairs()
        let owner = sessionProgress.owner
        syncThrottleQueue.async { [weak self] in
            guard let self, self.sessionProgress.owns(owner) else { return }
            let now = Date()
            if let last = self.lastSyncTriggeredAt {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < self.syncThrottleInterval {
                    // Within the throttle window — schedule one trailing run (coalesce).
                    guard self.pendingSyncWorkItem == nil else { return }
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, self.sessionProgress.owns(owner) else { return }
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
    private func performE2eSyncNow(trigger: String, completion: (() -> Void)? = nil) {
        syncLock.lock()
        guard !isSyncing else {
            if let completion { pendingSyncCompletions.append(completion) }
            syncLock.unlock()
            log.debug("[E2eSync] mode=full state=coalesced trigger=\(trigger)", subsystems: .mls)
            return
        }
        isSyncing = true
        syncProgressTicket = sessionProgress.begin("preparing")
        syncIncludesStandard = true
        standardSyncFinishing = false
        if let completion { activeSyncCompletions.append(completion) }
        syncLock.unlock()
        resumeOutgoingRetirements()
        resumeOutgoingReconciliation?()
        auditRetainedMembershipIfRequested()
        
        var cursors: [String: ScopeSyncCursorPayload] = [:]
        var membershipDates: [String: Date] = [:]
        let deviceLoginTime = loginTime
        // Resolve cursors on a background context — this scans all MLS channels (and may touch
        // MLS storage in `resolveSyncCursor`), which must not run on the main thread.
        let context = database.backgroundReadOnlyContext
        var candidateCids = Set<String>()
        context.performAndWait { candidateCids = Set(ChannelDTO.fetchAllJoinedMlsEnabled(context: context).map(\.cid)) }
        let scopes = Set(candidateCids.compactMap { try? ChannelId(cid: $0) }.map { mlsGroupCid(for: $0).rawValue })
        prepareLiveScopes(scopes) { [weak self] allowed in
        guard let self else { return }
        context.performAndWait {
            let channels = ChannelDTO.fetchAllJoinedMlsEnabled(context: context)
            for ch in channels where allowed.contains(ch.cid) {
                if let cursor = self.resolveSyncCursor(
                    cidString: ch.cid,
                    mlsJoinedAt: ch.mlsGroupJoinedAt,
                    memberCreatedAt: ch.membership?.memberCreatedAt,
                    deviceLoginTime: deviceLoginTime
                ) {
                    cursors[ch.mlsGroupCid] = cursor
                    membershipDates[ch.mlsGroupCid] = ch.membership?.memberCreatedAt?.bridgeDate
                }
            }
        }
        guard !cursors.isEmpty else {
            self.finishSync()
            return
        }
        self.syncLock.lock()
        self.activeSyncCids = Set(cursors.keys)
        self.activeSyncMembershipDates = membershipDates
        self.unverifiedLiveSyncScopes.formUnion(cursors.keys)
        self.successfulSyncScopes.removeAll()
        self.pendingSyncReadinessScopes.removeAll()
        self.syncLock.unlock()
        log.debug(
            "[E2eSync] mode=full state=started trigger=\(trigger) scope_count=\(cursors.count)",
            subsystems: .mls
        )
        self.replayDurablePendingEvents(scopeCids: Set(cursors.keys))
        self.startSyncPages(cursors: cursors)
        }
    }
    
    /// Called after a channel list API response is saved to the database.
    /// For each MLS-enabled channel whose local MLS group does not yet exist,
    /// performs an external join so the device can decrypt messages in that channel.
    /// For channels whose group already exists locally (e.g. MLS DB survived logout),
    /// ensures `mlsGroupJoinedAt` is set so E2E sync has a valid cursor.
    ///
    /// - Parameter cids: The MLS-enabled channel IDs from the saved channel list payload.
    /// Rank every persisted scope before native work. Recency changes ordering, never coverage.
    private func orderedBootstrapCids(_ candidates: Set<String>) -> [ChannelId] {
        readinessLock.lock(); let active = activeBootstrapCid; readinessLock.unlock()
        let context = database.backgroundReadOnlyContext
        var dates: [String: Date] = [:]
        context.performAndWait {
            for raw in candidates {
                guard let cid = try? ChannelId(cid: raw) else { continue }
                let dto = ChannelDTO.load(cid: cid, context: context)
                let scope = dto?.mlsGroupCid ?? raw
                let date = (dto?.lastMessageAt ?? dto?.updatedAt)?.bridgeDate ?? .distantPast
                dates[scope] = max(dates[scope] ?? .distantPast, date)
            }
        }
        return dates.keys.sorted {
            if $0 == active { return true }; if $1 == active { return false }
            return dates[$0] == dates[$1] ? $0 < $1 : (dates[$0] ?? .distantPast) > (dates[$1] ?? .distantPast)
        }.compactMap { try? ChannelId(cid: $0) }
    }

    private func applyStandardSyncPage(cid: String, events: [E2eeArchiveWire], owner: () throws -> Void) throws {
        let channelId = try ChannelId(cid: cid), encoder = JSONEncoder(), decoder = JSONDecoder.default
        try database.writeAndWait { session in
            try owner()
            for event in events {
                guard event["cid"].string == cid, let type = event["type"].string else { throw E2eeArchiveError.invalidData }
                let data = event["data"]
                guard let sequence = data["event_seq"].number else { throw E2eeArchiveError.invalidData }
                if let id = data["message_id"].string, let saved = session.message(id: id),
                   let previous = saved.standardEventSequence.flatMap(UInt64.init), previous > sequence { continue }
                switch type {
                case "message_new", "message_updated", "poll_choice_new", "poll_choice_deleted", "poll_choices_updated":
                    let message = try decoder.decode(MessagePayload.self, from: encoder.encode(data["message"]))
                    guard message.encryptedData == nil else { throw E2eeArchiveError.invalidData }
                    message.canonicalEventSequence = sequence
                    try session.saveMessage(payload: message, for: channelId, syncOwnReactions: true, cache: nil)
                case "message_deleted":
                    guard let id = data["message_id"].string else { throw E2eeArchiveError.invalidData }
                    if let message = session.message(id: id) {
                        guard message.channel?.cid == cid, message.encryptedData == nil else { throw E2eeArchiveError.invalidData }
                        let at = try decoder.decode(Date.self, from: encoder.encode(event["created_at"]))
                        message.deletedAt = at.bridgeDate
                        message.standardEventSequence = String(sequence)
                    }
                case "reaction":
                    guard let id = data["message_id"].string else { throw E2eeArchiveError.invalidData }
                    if let message = session.message(id: id) {
                        guard message.channel?.cid == cid, message.encryptedData == nil else { throw E2eeArchiveError.invalidData }
                        let counts = try decoder.decode([String: Int].self, from: encoder.encode(data["reaction_counts"]))
                        let reactions = try decoder.decode([MessageReactionPayload].self, from: encoder.encode(data["latest_reactions"]))
                        message.standardEventSequence = String(sequence)
                        message.reactionCounts = counts
                        message.latestReactions = try reactions.map { try session.saveReaction(payload: $0, cache: nil).id }
                    }
                default: throw E2eeSyncApplyError.unsupportedEvent(type: type)
                }
                try owner()
            }
        }
    }

    private func prepareLiveScopes(_ scopes: Set<String>, completion: @escaping (Set<String>) -> Void) {
        // Baseline combined scope transport owns protocol/application ordering and cursors.
        completion(scopes)
    }

    func handleNewEncryptedChannels(_ cids: [ChannelId]) {
        let owner = sessionProgress.owner
        syncThrottleQueue.async { [weak self] in
            guard let self, self.sessionProgress.owns(owner) else { return }
            let scopes = Set(cids.map { self.mlsGroupCid(for: $0).rawValue })
            self.prepareLiveScopes(scopes) { [weak self] allowed in
                guard let self, self.sessionProgress.owns(owner) else { return }
                self.handlePreparedEncryptedChannels(allowed.compactMap { try? ChannelId(cid: $0) })
            }
        }
    }

    func handlePersistedEncryptedChannels(_ payload: ChannelListPayload) {
        guard let user = mlsClient.userId else { return }
        // Metadata pages publish rows/profiles early; the full session inventory owns bootstrap.
        if sessionProgress.isInventoryBootstrapDeferred { return }
        let eligible = E2eeSessionInventory.channels(roots: payload.channels, topics: [], userId: user)
        handleNewEncryptedChannels(Set(eligible.values).compactMap { try? ChannelId(cid: $0) })
    }

    func beginSessionInventory() -> SessionSyncProgress.InventoryTicket? {
        if let owner = bootstrapOwnerStamp(),
           (try? mlsClient.readRecoveryCheckpoint(key: "session_bootstrap_manifest_v1")) == owner {
            sessionProgress.deferRestoredBootstrapPresentation()
        }
        return sessionProgress.beginInventory()
    }

    // A durable bootstrap milestone is a work index, never a send/readiness permission.
    private func bootstrapOwnerStamp() -> Data? {
        guard let (user, device, signer, _) = try? recoveryControlOwner() else { return nil }
        return try? JSONEncoder().encode([user, device, signer, apiClient.encoder.baseURL.absoluteString])
    }

    private func bootstrapStamp(_ cid: String, membershipDate: Date? = nil) -> Data? {
        guard let owner = bootstrapOwnerStamp(), mlsClient.loadPendingGenerationJoin(cid: cid) == nil,
              let id = try? ChannelId(cid: cid) else { return nil }
        let marker = mlsClient.loadGenerationMarker(cid: cid)
        guard marker == nil || marker?.status == "active" else { return nil }
        var membership = membershipDate
        if membership == nil {
            e2eReadContext.performAndWait {
                membership = ChannelDTO.load(cid: id, context: self.e2eReadContext)?.membership?.memberCreatedAt?.bridgeDate
            }
        }
        guard let membership else { return nil }
        return try? JSONEncoder().encode([owner.base64EncodedString(), cid,
            String(membership.timeIntervalSince1970), String(marker?.generation ?? 0),
            marker?.groupId?.base64EncodedString() ?? "", marker?.providerPath ?? ""])
    }

    private func hasCompletedBootstrap(_ cid: String, membershipDate: Date?) -> Bool {
        guard let account = mlsClient.userId, let stamp = bootstrapStamp(cid, membershipDate: membershipDate),
              recoveryControlAllowsReady(cid: cid) else { return false }
        do {
            let store = try mlsClient.membershipMutationStore()
            guard !store.hasIntent(cid: cid), try store.load(cid: cid) == nil,
                  try durableInboxStore.localJoinReceiptProof(accountId: account, scopeCid: cid) == nil else { return false }
            return try mlsClient.readRecoveryCheckpoint(key: "session_bootstrap_v1:" + cid) == stamp
        } catch { return false }
    }

    private func checkpointBootstrap(_ cid: String, owner: UUID) {
        do {
            try performMlsMutation(cidString: cid) {
                guard self.sessionProgress.owns(owner), let stamp = self.bootstrapStamp(cid),
                      let binding = self.bootstrapOwnerStamp() else { return }
                let key = "session_bootstrap_v1:" + cid
                if try self.mlsClient.readRecoveryCheckpoint(key: key) != stamp {
                    try self.mlsClient.writeRecoveryCheckpoint(stamp, key: key)
                }
                if try self.mlsClient.readRecoveryCheckpoint(key: "session_bootstrap_manifest_v1") != binding {
                    try self.mlsClient.writeRecoveryCheckpoint(binding, key: "session_bootstrap_manifest_v1")
                }
            }
        } catch {
            log.error("[MLS] bootstrap_checkpoint result=failed " + PrivacySafeLogMetadata.errorFields(error), subsystems: .mls)
        }
    }

    func failSessionInventory(_ ticket: SessionSyncProgress.InventoryTicket, retry: @escaping () -> Void) {
        sessionProgress.failInventory(ticket, retry: retry)
    }

    /// Runs after the complete root query is durable. It never delays root/profile publication.
    func completeSessionInventory(_ ticket: SessionSyncProgress.InventoryTicket, roots: ChannelListPayload,
                                  userId: String, projectId: String, retry: @escaping () -> Void) {
        guard sessionProgress.owns(ticket) else { return }
        var query = ChannelListQuery(filter: .and([
            .in(.members, values: [.init(userId: userId, projectId: projectId)]),
            .in(.channelRoles, values: ["owner", "moder", "member"]),
            .in(.channelType, values: [ChannelType.topic.rawValue]),
            .equal(.projectId, to: projectId), .equal(.isBlocked, to: false),
            .equal(.init(rawValue: "banned"), to: false),
            .equal(.init(rawValue: "include_parent"), to: true)
        ]), messagesLimit: 0)
        query.shouldLoadAllChannels = true
        apiClient.requestChannelMetadata(query: query) { [weak self] result in
            guard let self, self.sessionProgress.owns(ticket) else { return }
            switch result {
            case .failure:
                self.sessionProgress.failInventory(ticket, retry: retry)
            case .success(let topics):
                let size = max(1, query.pagination.pageSize)
                let batches = stride(from: 0, to: topics.channels.count, by: size).map {
                    Array(topics.channels[$0..<min($0 + size, topics.channels.count)])
                }
                WatchedChannelPageWriter.save(batches, persist: { batch, acknowledge in
                    self.database.write({ session in
                        guard self.sessionProgress.owns(ticket) else { throw E2eeMessageEpochRecoveryError.ownerReleased }
                        try roots.sessionOwner?(); try topics.sessionOwner?()
                        for row in batch { _ = try session.saveChannel(payload: row, query: nil, cache: nil) }
                    }, completion: acknowledge)
                }, completion: { [weak self] error in
                    guard let self, self.sessionProgress.owns(ticket) else { return }
                    guard error == nil else { self.sessionProgress.failInventory(ticket, retry: retry); return }
                    self.syncThrottleQueue.async { [weak self] in
                        guard let self, self.sessionProgress.owns(ticket) else { return }
                        do { try roots.sessionOwner?(); try topics.sessionOwner?() }
                        catch { self.sessionProgress.failInventory(ticket, retry: retry); return }
                        let inventory: (channels: [String: String], standard: [String: Bool])
                        do {
                            inventory = try self.currentEligibleInventory(E2eeSessionInventory.channels(
                                roots: roots.channels, topics: topics.channels, userId: userId, includingStandard: true), userId: userId)
                        } catch { self.sessionProgress.failInventory(ticket, retry: retry); return }
                        let owner = ticket.session
                        for (key, ready) in inventory.standard {
                            self.sessionProgress.record(scope: key, result: ready ? .ready : .blocked, owner: owner)
                        }
                        let scopes = Set(inventory.channels.values).filter { !$0.hasPrefix(Self.standardProgressPrefix) }
                        var joinedDates: [String: Date] = [:]
                        let context = self.database.backgroundReadOnlyContext
                        context.performAndWait {
                            let request = NSFetchRequest<ChannelDTO>(entityName: ChannelDTO.entityName)
                            request.predicate = NSPredicate(format: "cid IN %@", Array(scopes))
                            request.relationshipKeyPathsForPrefetching = ["membership"]
                            for row in (try? context.fetch(request)) ?? [] {
                                joinedDates[row.cid] = row.membership?.memberCreatedAt?.bridgeDate
                            }
                        }
                        let restored = scopes.filter { joinedDates[$0] != nil && self.hasCompletedBootstrap($0, membershipDate: joinedDates[$0]) }
                        self.readinessLock.lock(); self.dormantBootstrapScopes.formUnion(restored); self.readinessLock.unlock()
                        self.sessionProgress.restoreBootstrapMilestones(Set(restored), owner: owner)
                        self.sessionProgress.finishInventory(ticket, channels: inventory.channels, retry: { [weak self] in
                            self?.retrySessionReadiness(owner: owner)
                        })
                        let encrypted = Set(inventory.channels.values).filter { !$0.hasPrefix(Self.standardProgressPrefix) }
                        if encrypted.isEmpty, let stamp = self.bootstrapOwnerStamp() {
                            try? self.mlsClient.writeRecoveryCheckpoint(stamp, key: "session_bootstrap_manifest_v1")
                        }
                        self.handlePreparedEncryptedChannels(encrypted.compactMap { try? ChannelId(cid: $0) })
                    }
                })
            }
        }
    }

    /// Recheck membership after asynchronous pages/writes, without per-channel SQL or model mapping.
    /// A removal that arrived during inventory must not be resurrected by its earlier snapshot.
    private static let standardProgressPrefix = "standard|"

    private func currentEligibleInventory(_ inventory: [String: String], userId: String) throws -> (channels: [String: String], standard: [String: Bool]) {
        let context = database.backgroundReadOnlyContext
        return try context.performAndWait {
            var result: [String: String] = [:], standard: [String: Bool] = [:]
            let request = NSFetchRequest<ChannelDTO>(entityName: ChannelDTO.entityName)
            request.predicate = NSPredicate(format: "cid IN %@", Array(Set(inventory.keys).union(inventory.values)))
            request.relationshipKeyPathsForPrefetching = ["membership", "membership.user"]
            let fetched = try context.fetch(request)
            var rows = Dictionary(uniqueKeysWithValues: fetched.map { ($0.cid, $0) })
            let parents = Set(fetched.compactMap(\.parentcid)).subtracting(rows.keys)
            if !parents.isEmpty {
                let parentRequest = NSFetchRequest<ChannelDTO>(entityName: ChannelDTO.entityName)
                parentRequest.predicate = NSPredicate(format: "cid IN %@", Array(parents))
                parentRequest.relationshipKeyPathsForPrefetching = ["membership", "membership.user"]
                for row in try context.fetch(parentRequest) { rows[row.cid] = row }
            }
            for cid in inventory.keys {
                guard let row = rows[cid], row.deletedAt == nil, !row.isClosedTopic else { continue }
                let scope = row.mlsGroupCid
                let membership = row.membership ?? (scope != cid ? rows[scope]?.membership : nil)
                guard let member = membership, member.user.userId == userId, member.isJoined,
                      !member.isBanned, !member.isBlocked else { continue }
                let encrypted = row.mlsEnabled || (row.gate?.boolValue != true && scope != cid && rows[scope]?.mlsEnabled == true)
                if encrypted { result[cid] = scope }
                else {
                    let key = Self.standardProgressPrefix + cid
                    result[cid] = key
                    // Equivalent to Channel.canSendMessage, without eager relationship/model mapping.
                    standard[key] = row.memberCapabilities?.contains(ChannelCapability.sendMessage.rawValue) == true
                        || row.membership?.channelRoleRaw != MemberRole.member.rawValue
                }
            }
            return (result, standard)
        }
    }

    private func retireInventoryChannel(_ cid: ChannelId, topics: [ChannelId] = []) {
        let owner = sessionProgress.owner
        var removed = Set(topics.map(\.rawValue)); removed.insert(cid.rawValue)
        if cid.type != .topic {
            e2eReadContext.performAndWait {
                let request = NSFetchRequest<ChannelDTO>(entityName: ChannelDTO.entityName)
                request.predicate = NSPredicate(format: "parentcid == %@", cid.rawValue)
                if let children = try? self.e2eReadContext.fetch(request) { removed.formUnion(children.map(\.cid)) }
            }
            sessionProgress.excludeScope(cid.rawValue, owner: owner)
        }
        sessionProgress.excludeChannels(removed, owner: owner)
        if mlsGroupCid(for: cid) == cid { setReadiness(.needsRetry, for: cid.rawValue) }
    }

    private func observedScopeMembership(_ cid: String) -> Bool? {
        var allowed: Bool?
        e2eReadContext.performAndWait {
            guard let channelId = try? ChannelId(cid: cid), let dto = ChannelDTO.load(cid: channelId, context: self.e2eReadContext) else { return }
            allowed = dto.deletedAt == nil && dto.membership?.isJoined == true
                && dto.membership?.isBanned != true && dto.membership?.isBlocked != true
                && dto.membership?.user.userId == self.mlsClient.userId
        }
        return allowed
    }

    private func retrySessionReadiness(owner: UUID) {
        syncThrottleQueue.async { [weak self] in
            guard let self, self.sessionProgress.owns(owner) else { return }
            let incomplete = self.sessionProgress.incompleteScopes
            let standardIds = incomplete.filter { $0.hasPrefix(Self.standardProgressPrefix) }.map { String($0.dropFirst(Self.standardProgressPrefix.count)) }
            if let user = self.mlsClient.userId, !standardIds.isEmpty {
                do {
                    let current = try self.currentEligibleInventory(Dictionary(uniqueKeysWithValues: standardIds.map { ($0, $0) }), userId: user)
                    for cid in standardIds where current.channels[cid] == nil { self.sessionProgress.excludeChannel(cid, owner: owner) }
                    for (key, ready) in current.standard { self.sessionProgress.record(scope: key, result: ready ? .ready : .blocked, owner: owner) }
                } catch { /* Keep truthful partial; a store failure is never Ready. */ }
            }
            let cids = self.orderedBootstrapCids(incomplete.filter { !$0.hasPrefix(Self.standardProgressPrefix) })
            for cid in cids { self.setReadiness(.restoring, for: cid.rawValue) }
            self.sessionProgress.installInventoryRetry(owner: owner) { [weak self] in self?.retrySessionReadiness(owner: owner) }
            if self.bootstrapQueue.enqueue(cids) { self.runNextBootstrap() }
        }
    }

    /// A genuinely new connection may resume a settled transport failure once. Metadata
    /// refresh, foreground, pong and duplicate notifications cannot renew that budget.
    func resumeBootstrapAfterConnection(_ connectionId: String) {
        let owner = sessionProgress.owner
        readinessLock.lock()
        guard lastBootstrapConnectionId != connectionId else { readinessLock.unlock(); return }
        lastBootstrapConnectionId = connectionId
        let failed = readinessByCid.compactMap { $0.value == .infrastructureRetryable ? $0.key : nil }
        readinessLock.unlock()
        guard !failed.isEmpty else { return }
        syncThrottleQueue.async { [weak self] in
            guard let self, self.sessionProgress.owns(owner) else { return }
            let cids = self.orderedBootstrapCids(Set(failed)).filter {
                self.observedScopeMembership($0.rawValue) == true && !self.bootstrapQueue.contains($0)
            }
            for cid in cids { self.setReadiness(.restoring, for: cid.rawValue) }
            if self.bootstrapQueue.enqueue(cids) { self.runNextBootstrap() }
        }
    }

    private func handlePreparedEncryptedChannels(_ cids: [ChannelId]) {
        let ordered = orderedBootstrapCids(Set(cids.map(\.rawValue)))
        // Discovery is not retry authority: repeated metadata/foreground callbacks do not
        // restart a failed budget. Explicit open/retry and authoritative events still can.
        let candidates = ordered.filter { cid in
            readinessLock.lock(); defer { readinessLock.unlock() }
            if dormantBootstrapScopes.contains(cid.rawValue) { return false }
            guard readinessByCid[cid.rawValue] == nil else { return false }
            readinessByCid[cid.rawValue] = .restoring
            return true
        }
        // Reserve the whole continuation before starting its first scope. Every scope uses
        // runNextBootstrap's existing local/Welcome/retained-candidate/admission decisions.
        if bootstrapQueue.enqueue(candidates) || candidates.isEmpty { runNextBootstrap() }
    }

    func localGroupEpoch(for cid: ChannelId, completion: @escaping (UInt64?) -> Void) {
        let groupCid = mlsGroupCid(for: cid).rawValue
        let user = mlsClient.userId
        mutationExecutor.enqueue(scopeIds: [groupCid], priority: .low) { [weak self] in
            guard let self, self.mlsClient.userId == user else { completion(nil); return }
            completion(self.mlsClient.localGroupEpoch(cid: groupCid))
        }
    }

    func readiness(for cid: ChannelId) -> E2eeChannelReadiness {
        let groupCid = mlsGroupCid(for: cid).rawValue
        if !recoveryControlAllowsReady(cid: groupCid) {
            if let state = trackedReadiness(for: groupCid), ![.ready, .recovered, .historyIncomplete].contains(state) {
                return state
            }
            return .restoring
        }
        if let store = try? mlsClient.membershipMutationStore(),
           store.hasIntent(cid: groupCid) || (try? store.load(cid: groupCid)) != nil { return .needsRetry }
        readinessLock.lock()
        let state = readinessByCid[groupCid]
        readinessLock.unlock()
        if let state {
            if [.ready, .recovered, .historyIncomplete].contains(state),
               mlsClient.hasNonOperationalGroup(cid: groupCid) { return .needsRetry }
            return state
        }
        return mlsClient.isGroupLoaded(cid: groupCid)
            && !mlsClient.hasNonOperationalGroup(cid: groupCid) ? .ready : .restoring
    }

    func ensureE2eeReady(
        for cid: ChannelId,
        completion: @escaping (E2eeChannelReadiness) -> Void
    ) {
        let groupCid = mlsGroupCid(for: cid)
        readinessLock.lock(); activeBootstrapCid = groupCid.rawValue; dormantBootstrapScopes.remove(groupCid.rawValue); readinessLock.unlock()
        let current = readiness(for: groupCid)
        if current == .ready || current == .recovered || current == .historyIncomplete {
            completion(current)
            return
        }
        readinessLock.lock()
        readinessCallbacks[groupCid.rawValue, default: []].append(completion)
        readinessLock.unlock()
        if bootstrapQueue.enqueuePriority(groupCid) { runNextBootstrap() }
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

    private func recoveryControlOwner() throws -> (String, String, String, Identity) {
        guard let user = mlsClient.userId, let device = mlsClient.currentDeviceId,
              let identity = mlsClient.identity else { throw ClientError.MlsNoIdentityError() }
        let signer = SHA256.hash(data: identity.signaturePublicKey()).map { String(format: "%02x", $0) }.joined()
        return (user, device, signer, identity)
    }

    private func observeRecoveryControl(_ state: MlsGenerationStatePayload, cid: ChannelId) throws -> MlsRecoveryControlCheckpoint? {
        guard let control = state.recoveryControl else { return nil }
        return try performMlsMutation(cidString: cid.rawValue) {
            guard state.isValidIdentity(installedGeneration: 0) else { throw MlsRecoveryControlError.invalidMetadata }
            let (user, device, signer, identity) = try self.recoveryControlOwner()
            let record = MlsRecoveryControlCheckpoint(userId: user, deviceId: device, signerSha256: signer,
                cid: cid.rawValue, generation: UInt64(state.groupGeneration), groupId: state.groupId.map { Data($0) }, control: control)
            let selected = try self.mlsClient.recoveryControlStore().observe(record) {
                guard self.mlsClient.userId == user, self.mlsClient.currentDeviceId == device,
                      self.mlsClient.identity === identity else { throw ClientError.Unexpected("mls_control_owner_changed") }
            }
            guard selected.generation == record.generation, selected.control == record.control else {
                throw ClientError.Unexpected("mls_control_observation_stale")
            }
            return selected
        }
    }

    private func installedRecoveryControl(cid: String) throws -> MlsRecoveryControlCheckpoint? {
        try performMlsMutation(cidString: cid) {
            let (user, device, signer, _) = try self.recoveryControlOwner()
            return try self.mlsClient.recoveryControlStore().load(userId: user, deviceId: device, signerSha256: signer, cid: cid)
        }
    }

    private func recoveryControlAllowsReady(cid: String) -> Bool {
        do {
            guard let control = try installedRecoveryControl(cid: cid) else { return false }
            let marker = mlsClient.loadGenerationMarker(cid: cid)
            return control.control.action != .manualInterventionRequired
                && control.generation == (marker?.generation ?? 0)
                && (control.generation == 0 || control.groupId == marker?.groupId)
        } catch { return false }
    }

    private func runNextBootstrap() {
        let owner = sessionProgress.owner
        // Metadata/cache callbacks may complete synchronously. Continue on the
        // existing session lane instead of recursing once per prepared scope.
        syncThrottleQueue.async { [weak self] in
            guard let self, self.sessionProgress.owns(owner) else { return }
            self.runNextBootstrapTurn()
        }
    }

    private func runNextBootstrapTurn() {
        let point = bootstrapQueue.takeSyncBatch(pointOnly: true)
        if !point.isEmpty { runBootstrapBatchSync(point, sessionBatch: false); return }
        guard let cid = bootstrapQueue.dequeue() else {
            if bootstrapQueue.takeFullSyncRequest() {
                runBootstrapBatchSync(bootstrapQueue.takeSyncBatch(limit: Int.max), full: true)
                return
            }
            let batch = bootstrapQueue.takeSyncBatch()
            if !batch.isEmpty { runBootstrapBatchSync(batch) }
            return
        }
        let workStarted = ProcessInfo.processInfo.systemUptime
        readinessLock.lock(); bootstrapStartedAt[cid.rawValue] = workStarted; readinessLock.unlock()
        let alias = SHA256.hash(data: Data(cid.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        log.info("session_bootstrap scope_sha256=\(alias) stage=started result=pending elapsed_ms=0", subsystems: .mls)

        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        trace.info(
            stage: "bootstrap_started",
            source: "bootstrap",
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            readiness: E2eeChannelReadiness.syncing.rawValue,
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue)
        )
        setReadiness(.syncing, for: cid.rawValue)
        let progressOwner = sessionProgress.owner
        let ownerIdentity = mlsClient.identity
        let ownerUser = mlsClient.userId
        let ownerDevice = mlsClient.currentDeviceId
        apiClient.request(endpoint: .mlsGeneration(cid: cid)) { [weak self] result in
            guard let self, self.sessionProgress.owns(progressOwner), self.mlsClient.identity === ownerIdentity,
                  self.mlsClient.userId == ownerUser, self.mlsClient.currentDeviceId == ownerDevice else { return }
            switch result {
            case .success(let state):
                guard state.capability.protocolVersion
                        == MlsRebootstrapCapabilityPayload.currentProtocolVersion,
                      state.capability.repairTimeoutSeconds == 15 * 60 else {
                    self.finishBootstrap(cid: cid, state: .clientUpgradeRequired)
                    return
                }
                do {
                    let control = try self.observeRecoveryControl(state, cid: cid)
                    if control?.control.action == .manualInterventionRequired {
                        self.finishBootstrap(cid: cid, state: .needsRetry)
                        return
                    }
                } catch {
                    self.finishBootstrap(cid: cid, state: .infrastructureRetryable)
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
                    // An offline reset recipient may already have a durable Welcome.
                    // Reconcile an existing candidate first; otherwise drain that Welcome
                    // before constructing a competing external commit.
                    if self.mlsClient.loadPendingGenerationJoin(cid: cid.rawValue) != nil {
                        self.externalJoinAuthoritativeGeneration(cid: cid, trace: trace)
                    } else {
                        self.afterBootstrapDurableTurns(cid) { [weak self] in
                            guard let self else { return }
                            let marker = self.mlsClient.loadGenerationMarker(cid: cid.rawValue)
                            if marker?.generation == UInt64(state.groupGeneration),
                               marker?.groupId == state.groupId.map({ Data($0) }),
                               self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                               !self.mlsClient.hasNonOperationalGroup(cid: cid.rawValue) {
                                self.prepareBootstrapBatchSync(cid)
                            } else {
                                self.externalJoinAuthoritativeGeneration(cid: cid, trace: trace)
                            }
                        }
                    }
                    return
                }
                if self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                   !self.mlsClient.hasNonOperationalGroup(cid: cid.rawValue),
                   !self.hasLocalJoinReceipt(for: cid.rawValue) {
                    self.prepareBootstrapBatchSync(cid)
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
        // Intake/durable Welcome processing precedes admission without a per-scope HTTP sync.
        replayDurablePendingEvents(scopeCids: [cid.rawValue])
        afterBootstrapDurableTurns(cid) { [weak self] in
            guard let self else { return }
            let groupLoaded = self.mlsClient.isGroupLoaded(cid: cid.rawValue)
            let hasReceipt = self.hasLocalJoinReceipt(for: cid.rawValue)
            let retainedGroupIsNonOperational = self.mlsClient.hasNonOperationalGroup(cid: cid.rawValue)
            trace.info(
                stage: "bootstrap_presync_finished",
                source: "bootstrap",
                result: groupLoaded && !retainedGroupIsNonOperational && !hasReceipt ? "group_ready" : "join_required",
                receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                groupLoaded: groupLoaded
            )
            if groupLoaded, !retainedGroupIsNonOperational, !hasReceipt {
                self.prepareBootstrapBatchSync(cid)
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
            let reason: E2eeMlsRolloutMetricReason = hasTypedPrerequisite && !retainedGroupIsNonOperational
                ? .noMatchingKeyPackage : .activeMemberRecovery

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
            self.externalJoinChannel(
                cid: cid,
                requiresActiveMemberRecovery: retainedGroupIsNonOperational || !hasTypedPrerequisite,
                replaceRetainedGroup: retainedGroupIsNonOperational
            ) { [weak self] error in
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
                self.prepareBootstrapBatchSync(cid)
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
            self.prepareBootstrapBatchSync(cid)
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
                      receipt.operationKey == checkpoint.completeBody.operationKey,
                      receipt.expectedGeneration == checkpoint.completeBody.expectedGeneration,
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
                let installedOwner = mlsClient.identity
                apiClient.request(endpoint: .mlsGeneration(cid: cid)) { [weak self] result in
                    guard let self, self.mlsClient.identity === installedOwner else { return }
                    do {
                        let state = try result.get()
                        guard let control = try self.observeRecoveryControl(state, cid: cid),
                              control.generation == UInt64(receipt.currentGeneration),
                              control.groupId == receipt.groupId.map({ Data($0) }) else {
                            throw MlsRecoveryControlError.generationBindingConflict
                        }
                        self.removeMlsRebootstrapCheckpoint(cid: cid.rawValue)
                        self.removeMlsRebootstrapClaimIntent(cid: cid.rawValue)
                        if control.control.action == .manualInterventionRequired {
                            self.finishBootstrap(cid: cid, state: .needsRetry)
                        } else {
                            self.continueBootstrapAfterGenerationDiscovery(cid: cid, trace: trace)
                        }
                    } catch {
                        // Keep installed group and operation checkpoint; next normal wake observes
                        // authority again. A successful receipt never substitutes for that authority.
                        self.finishBootstrap(cid: cid, state: .infrastructureRetryable)
                    }
                }
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

    private func hasVerifiedLiveSync(_ cid: String) -> Bool {
        syncLock.lock(); defer { syncLock.unlock() }
        return !unverifiedLiveSyncScopes.contains(cid)
    }

    private func bootstrapCompletionState(for cid: ChannelId) -> E2eeChannelReadiness {
        func blocked(_ reason: String, _ state: E2eeChannelReadiness = .needsRetry) -> E2eeChannelReadiness {
            let alias = SHA256.hash(data: Data(cid.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
            log.info("session_readiness_guard scope_sha256=\(alias) reason=\(reason)", subsystems: .mls)
            return state
        }
        guard observedScopeMembership(cid.rawValue) == true else { return blocked("membership") }
        guard hasVerifiedLiveSync(cid.rawValue) else { return blocked("live_sync", .infrastructureRetryable) }
        if isScopeBlocked(cid.rawValue) { return blocked("protocol") }
        if let store = try? mlsClient.membershipMutationStore(),
           store.hasIntent(cid: cid.rawValue) || (try? store.load(cid: cid.rawValue)) != nil { return blocked("membership_mutation") }
        guard mlsClient.isGroupLoaded(cid: cid.rawValue) else { return blocked("group_missing", .failed) }
        if mlsClient.hasNonOperationalGroup(cid: cid.rawValue) { return blocked("group_nonoperational") }
        // This remains a lifecycle/sync UI state. `encryptedMessage` independently evaluates
        // crypto safety, so a merged exact receipt may send while post-sync reconciles.
        if hasLocalJoinReceipt(for: cid.rawValue) { return blocked("join_receipt") }
        return .ready
    }

    private func prepareBootstrapBatchSync(_ cid: ChannelId) {
        setReadiness(.syncing, for: cid.rawValue)
        bootstrapQueue.prepareForBatchSync(cid)
        runNextBootstrap()
    }

    private func afterBootstrapDurableTurns(_ cid: ChannelId, completion: @escaping () -> Void) {
        let owner = sessionProgress.owner
        let operation = BlockOperation { [weak self] in
            guard let self, self.sessionProgress.owns(owner), let user = self.mlsClient.userId else { return }
            self.durableApplyLock.lock()
            let pending = self.scheduledDurableDrains.contains("\(user)|\(cid.rawValue)")
            self.durableApplyLock.unlock()
            if pending { self.afterBootstrapDurableTurns(cid, completion: completion) }
            else { completion() }
        }
        operation.queuePriority = .low
        enqueueGroupOperation(operation, cidStrings: [cid.rawValue])
    }

    private func runBootstrapBatchSync(_ cids: [ChannelId], full: Bool = false, sessionBatch: Bool = true) {
        let owner = sessionProgress.owner
        if sessionBatch { sessionProgress.startReadiness(owner: owner) }
        let completed = { [weak self] in
            guard let self, self.sessionProgress.owns(owner) else { return }
            let repair = cids.filter { self.hasVerifiedLiveSync($0.rawValue) && self.isScopeBlocked($0.rawValue) }
            self.recoverRetainedGroups(repair) { [weak self] in
                guard let self, self.sessionProgress.owns(owner) else { return }
                for cid in cids {
                    let state = self.hasVerifiedLiveSync(cid.rawValue)
                        ? self.bootstrapCompletionState(for: cid) : .infrastructureRetryable
                    self.finishBootstrap(cid: cid, state: state, advanceQueue: false)
                }
                self.bootstrapQueue.finishSyncBatch(cids)
                self.runNextBootstrap()
            }
        }
        if full { performE2eSyncNow(trigger: "bootstrap_continuation", completion: completed) }
        else {
            let remaining = scopesNeedingBootstrapSync(cids)
            if remaining.isEmpty { completed() }
            else { performE2eChannelSync(cids: Set(remaining.map(\.rawValue)), completion: completed) }
        }
    }

    private func syncMembershipDates(_ cids: Set<String>) -> [String: Date] {
        let context = database.backgroundReadOnlyContext
        return context.performAndWait {
            let request = NSFetchRequest<ChannelDTO>(entityName: ChannelDTO.entityName)
            request.predicate = NSPredicate(format: "cid IN %@", Array(cids))
            request.relationshipKeyPathsForPrefetching = ["membership"]
            return Dictionary(uniqueKeysWithValues: ((try? context.fetch(request)) ?? []).compactMap { row in
                row.membership?.memberCreatedAt.map { (row.cid, $0.bridgeDate) }
            })
        }
    }

    private func scopesNeedingBootstrapSync(_ cids: [ChannelId]) -> [ChannelId] {
        let owner = sessionProgress.owner
        let memberships = syncMembershipDates(Set(cids.map(\.rawValue)))
        readinessLock.lock()
        let started = Dictionary(uniqueKeysWithValues: cids.compactMap { cid in
            bootstrapStartedAt[cid.rawValue].map { (cid.rawValue, $0) }
        })
        readinessLock.unlock()
        syncLock.lock()
        let coverage = Dictionary(uniqueKeysWithValues: cids.compactMap { cid -> (String, LiveSyncCoverage)? in
            guard let witness = liveSyncCoverage[cid.rawValue],
                  witness.demand == (scopeSyncDemand[cid.rawValue]?.id ?? owner),
                  !unverifiedLiveSyncScopes.contains(cid.rawValue) else { return nil }
            return (cid.rawValue, witness)
        })
        syncLock.unlock()
        return cids.filter { cid in
            guard let since = started[cid.rawValue], let witness = coverage[cid.rawValue],
                  witness.completedAt >= since, let requestedMembership = witness.membershipDate,
                  requestedMembership == memberships[cid.rawValue],
                  witness.marker == mlsClient.loadGenerationMarker(cid: cid.rawValue),
                  bootstrapCompletionState(for: cid) == .ready else { return true }
            return false
        }
    }

    private func finishBootstrap(cid: ChannelId, state: E2eeChannelReadiness, advanceQueue: Bool = true) {
        // Historical recovery belongs to an explicitly queried page, never a broad live-gap epoch scan.
        let trace = E2eeJoinTrace.Context(cid: cid.rawValue)
        setReadiness(state, for: cid.rawValue)
        let actual = trackedReadiness(for: cid.rawValue) ?? state
        readinessLock.lock(); let started = bootstrapStartedAt.removeValue(forKey: cid.rawValue); readinessLock.unlock()
        let alias = SHA256.hash(data: Data(cid.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - (started ?? ProcessInfo.processInfo.systemUptime)) * 1000)
        let result = [.ready, .recovered, .historyIncomplete].contains(actual) ? "ready" : [.failed, .infrastructureRetryable].contains(actual) ? "failed" : "blocked"
        log.info("session_bootstrap scope_sha256=\(alias) stage=settled result=\(result) elapsed_ms=\(elapsed)", subsystems: .mls)
        if ![.ready, .recovered, .historyIncomplete].contains(actual) {
            // A terminal queue turn can leave an intentional wait/rebootstrap state.
            // That is settled partial work, never an endlessly spinning success ticket.
            sessionProgress.record(scope: cid.rawValue,
                result: [.failed, .infrastructureRetryable].contains(actual) ? .failed : .blocked,
                owner: sessionProgress.owner)
        }
        let needsCatchUp = advanceQueue ? bootstrapQueue.finish(cid) : false
        trace.info(
            stage: "bootstrap_finished",
            source: "bootstrap",
            result: state.rawValue,
            receipt: joinReceiptTraceStatus(for: cid.rawValue),
            readiness: state.rawValue,
            groupLoaded: mlsClient.isGroupLoaded(cid: cid.rawValue),
            deferredSync: needsCatchUp
        )
        guard advanceQueue else { return }
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

    private func setReadiness(_ requestedState: E2eeChannelReadiness, for cidString: String) {
        let owner = sessionProgress.owner
        let successStates: Set<E2eeChannelReadiness> = [.ready, .recovered, .historyIncomplete]
        var state = requestedState
        if successStates.contains(requestedState) {
            let verified = (try? performMlsMutation(cidString: cidString) {
                guard self.sessionProgress.owns(owner), self.recoveryControlAllowsReady(cid: cidString),
                      let cid = try? ChannelId(cid: cidString),
                      self.bootstrapCompletionState(for: cid) == .ready,
                      let group = try? self.mlsClient.loadGroup(with: cidString) else { return false }
                return self.canEncrypt(in: group, scopeCid: cidString)
            }) ?? false
            if !verified { state = .needsRetry }
        }
        guard sessionProgress.owns(owner) else { return }
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
        let progressResult: SessionSyncProgress.ScopeResult
        if successStates.contains(state) { progressResult = .ready }
        else if [.failed, .infrastructureRetryable].contains(state) { progressResult = .failed }
        else if terminalStates.contains(state) { progressResult = .blocked }
        else { progressResult = .pending }
        if successStates.contains(state) { checkpointBootstrap(cidString, owner: owner) }
        sessionProgress.record(scope: cidString, result: progressResult, owner: owner,
            invalidateReady: state == .joining || state == .rebootstrapping)
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

    private func installedGenerationWelcomeBoundary(for cidString: String) throws -> E2eSyncEventEnvelope? {
        guard mlsClient.loadPendingGenerationJoin(cid: cidString) == nil,
              let marker = mlsClient.loadGenerationMarker(cid: cidString), marker.status == "active", marker.generation > 0,
              let groupId = marker.groupId, let account = mlsClient.userId, let device = mlsClient.currentDeviceId else { return nil }
        return try durableInboxStore.installedWelcomeBoundary(accountId: account, scopeCid: cidString,
            generation: marker.generation, groupId: groupId, deviceId: device,
            onContinuation: { [weak self] in
                self?.continueWelcomeBoundaryScan(cidString: cidString, account: account, device: device,
                    generation: marker.generation, groupId: groupId)
            })
    }

    private func continueWelcomeBoundaryScan(cidString: String, account: String, device: String,
                                             generation: UInt64, groupId: Data) {
        guard let provider = mlsClient.provider, let identity = mlsClient.identity,
              let key = try? E2eeDurableInboxStore.welcomeBoundaryScope(accountId: account, scopeCid: cidString,
                generation: generation, groupId: groupId, deviceId: device) else { return }
        let wakeKey = key + String(describing: ObjectIdentifier(provider)) + String(describing: ObjectIdentifier(identity))
        durableApplyLock.lock()
        let inserted = welcomeBoundaryWakes.insert(wakeKey).inserted
        durableApplyLock.unlock()
        guard inserted else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.durableApplyLock.lock(); self.welcomeBoundaryWakes.remove(wakeKey); self.durableApplyLock.unlock()
            guard self.mlsClient.userId == account, self.mlsClient.currentDeviceId == device,
                  self.mlsClient.provider === provider, self.mlsClient.identity === identity,
                  self.mlsClient.loadPendingGenerationJoin(cid: cidString) == nil,
                  let marker = self.mlsClient.loadGenerationMarker(cid: cidString), marker.status == "active",
                  marker.generation == generation, marker.groupId == groupId else { return }
            do {
                if try self.installedGenerationWelcomeBoundary(for: cidString) != nil,
                   self.mlsClient.userId == account, self.mlsClient.currentDeviceId == device,
                   self.mlsClient.provider === provider, self.mlsClient.identity === identity,
                   self.mlsClient.loadPendingGenerationJoin(cid: cidString) == nil,
                   let cid = try? ChannelId(cid: cidString) {
                    self.retryPendingGroupApplications(in: cid)
                    self.ensureE2eeReady(for: cid, completion: { _ in })
                }
            } catch {
                log.error("[E2EReadiness] state=needsRetry reason=welcome_boundary_proof_unavailable", subsystems: .mls)
            }
        }
    }

    private func hasLocalJoinReceipt(for cidString: String) -> Bool {
        if mlsClient.loadPendingGenerationJoin(cid: cidString)?.candidateFenceVersion == 1 { return true }
        guard let accountId = mlsClient.userId else { return false }
        do {
            if try installedGenerationWelcomeBoundary(for: cidString) != nil { return false }
            let finalized = try performMlsMutation(cidString: cidString) {
                guard self.mlsClient.userId == accountId,
                      self.mlsClient.loadPendingGenerationJoin(cid: cidString) == nil,
                      let receipt = try self.durableInboxStore.localJoinReceiptProof(accountId: accountId, scopeCid: cidString) else { return false }
                var witness: E2eeDurableInboxStore.InstalledJoinReceiptWitness?
                if receipt.status == .merged, receipt.requestDeviceId == self.mlsClient.currentDeviceId,
                   !self.mlsClient.hasNonOperationalGroup(cid: cidString),
                   let group = try? self.mlsClient.loadGroup(with: cidString), group.epoch() >= receipt.epoch,
                   let marker = self.mlsClient.loadGenerationMarker(cid: cidString), marker.status == "active" {
                    witness = .init(receipt: receipt, generation: marker.generation, groupId: marker.groupId)
                }
                return try self.durableInboxStore.finalizeAppliedLocalJoinReceiptIfPossible(
                    accountId: accountId, scopeCid: cidString, installedWitness: witness
                )
            }
            if finalized, let cid = try? ChannelId(cid: cidString) {
                normalizeHistoricalApplications(cid: cid)
                retryPendingGroupApplications(in: cid)
                reDecryptPendingMessages(in: cid)
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
    func repairLiveScope(_ cid: ChannelId, completion: @escaping (E2eeChannelReadiness) -> Void) {
        let groupCid = mlsGroupCid(for: cid)
        runSync(forCidStrings: [groupCid.rawValue]) { [weak self] in
            self?.ensureE2eeReady(for: groupCid, completion: completion)
        }
    }

    func performE2eChannelSync(cid: ChannelId, protocolEvent: MLSProtocolMessagePayload? = nil) {
        let scope = mlsGroupCid(for: cid)
        var protocolDigest: String?
        if let event = protocolEvent, let payload = event.processData {
            // Realtime is a wake-up hint, never acceptance or Ready authority.
            // Two deliveries of identical protocol bytes must not look like a
            // newer demand arriving during the first request.
            var hash = SHA256()
            let groupId = event.groupId ?? []
            hash.update(data: Data("\(scope.rawValue)|\(event.type.rawValue)|\(event.groupGeneration)|\(event.epoch)|\(groupId.count)|".utf8))
            hash.update(data: Data(groupId))
            hash.update(data: payload)
            protocolDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        syncLock.lock()
        if protocolDigest == nil || scopeSyncDemand[scope.rawValue]?.protocolDigest != protocolDigest {
            // A->B->A must stay newer than the HTTP that captured the first A.
            scopeSyncDemand[scope.rawValue] = ScopeSyncDemand(id: UUID(), protocolDigest: protocolDigest)
        }
        syncLock.unlock()
        // Preparation already owns this scope. Wakeups before its batch starts are
        // covered by that batch; wakeups during transport retain one trailing turn.
        guard !bootstrapQueue.deferSyncIfAdmitted(scope) else { return }
        runSync(forCidStrings: [scope.rawValue], completion: nil)
    }

    /// Owner diagnostics: read at most 500 retained envelopes without changing cursor,
    /// membership or MLS state. Only protocol identity/hash is logged; never raw blobs.
    private func auditRetainedMembershipIfRequested() {
#if DEBUG
        guard let cid = ProcessInfo.processInfo.environment["ERMIS_MLS_AUDIT_CID"],
              let accountId = mlsClient.userId, (try? ChannelId(cid: cid)) != nil else { return }
        let context = database.backgroundReadOnlyContext
        context.perform {
            do {
                let request = NSFetchRequest<E2eeInboxEventDTO>(entityName: E2eeInboxEventDTO.entityName)
                request.predicate = NSPredicate(format: "accountId == %@ AND scopeCid == %@", accountId, cid)
                request.sortDescriptors = [NSSortDescriptor(keyPath: \E2eeInboxEventDTO.createdAt, ascending: true)]
                request.fetchLimit = 500
                let records = try context.fetch(request)
                log.info("mls_membership_audit stage=retained rows=\(records.count) limit=500", subsystems: .mls)
                for record in records {
                    let envelope = try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: record.rawEnvelope)
                    switch envelope.event {
                    case .protocol(let data):
                        let hash = data.commit.map { SHA256.hash(data: Data($0)).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "none"
                        log.info(
                            "mls_membership_trace stage=protocol event_id=\(envelope.eventId) epoch=\(data.epoch) "
                                + "sender_user=\(data.user.userId) sender_device=\(data.deviceId ?? "none") commit_hash=\(hash)",
                            subsystems: .mls
                        )
                    case .memberRemoved(let data, let time):
                        log.info(
                            "mls_membership_trace stage=removed event_id=\(envelope.eventId) created_at_ms=\(Int64(time.timeIntervalSince1970 * 1000)) "
                                + "self_remove=\(data.selfRemove) target_user=\(data.memberContainer.member?.userId ?? "none")",
                            subsystems: .mls
                        )
                    default: break
                    }
                }
            } catch {
                log.error("mls_membership_audit stage=read_failed", subsystems: .mls)
            }
        }
#endif
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
        syncProgressTicket = sessionProgress.begin("preparing")
        activeSyncCids = cidStrings
        unverifiedLiveSyncScopes.formUnion(cidStrings)
        successfulSyncScopes.removeAll()
        pendingSyncReadinessScopes.removeAll()
        if let completion { activeSyncCompletions = [completion] }
        syncLock.unlock()

        var cursors: [String: ScopeSyncCursorPayload] = [:]
        var membershipDates: [String: Date] = [:]
        let deviceLoginTime = loginTime
        let context = database.backgroundReadOnlyContext
        prepareLiveScopes(cidStrings) { [weak self] allowed in
        guard let self else { return }
        context.performAndWait {
            for cidString in allowed {
                guard let cid = try? ChannelId(cid: cidString),
                      let dto = ChannelDTO.load(cid: cid, context: context) else { continue }
                if let cursor = self.resolveSyncCursor(
                    cidString: cidString,
                    mlsJoinedAt: dto.mlsGroupJoinedAt,
                    memberCreatedAt: dto.membership?.memberCreatedAt,
                    deviceLoginTime: deviceLoginTime
                ) {
                    cursors[cidString] = cursor
                    membershipDates[cidString] = dto.membership?.memberCreatedAt?.bridgeDate
                }
            }
        }

        guard !cursors.isEmpty else {
            self.finishSync()
            log.debug(
                "[E2eSync] mode=scoped state=skipped reason=group_not_joined scope_count=\(cidStrings.count)",
                subsystems: .mls
            )
            return
        }
        log.debug("[E2eSync] Starting sync for \(cursors.count) channel(s)", subsystems: .mls)
        self.replayDurablePendingEvents(scopeCids: Set(cursors.keys))
        self.syncLock.lock(); self.activeSyncMembershipDates = membershipDates; self.syncLock.unlock()
        self.startSyncPages(cursors: cursors)
        }
    }

    /// One initial cursor map covers the session; only actual event/removal
    /// pagination requires further HTTP. Durable page/capacity guards still apply.
    private func startSyncPages(cursors: [String: ScopeSyncCursorPayload]) {
        sessionProgress.phase("syncing")
        guard !cursors.isEmpty else {
            finishSync()
            return
        }
        syncLock.lock()
        pendingInitialSyncCursorBatches.removeAll()
        syncLock.unlock()
        syncPage(cursors: cursors)
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

    private func syncPage(cursors: [String: ScopeSyncCursorPayload], materializationRetries: [String: Int] = [:]) {
        let owner = sessionProgress.owner
        syncLock.lock()
        let requestedDemands = Dictionary(uniqueKeysWithValues: cursors.keys.map { ($0, scopeSyncDemand[$0]?.id ?? owner) })
        syncLock.unlock()
        for (cid, cursor) in cursors {
            log.info("mls_scope_trace stage=requested cid=\(cid) event_id=\(cursor.eventId) created_at=\(cursor.createdAt)", subsystems: .mls)
        }
        let body = E2eSyncRequestBody(cursors: cursors, removedCursor: loadRemovedSyncCursor())
        apiClient.request(endpoint: .e2eSync(body: body)) { [weak self] result in
            guard let self, self.sessionProgress.owns(owner) else { return }
            switch result {
            case .failure(let error):
                log.error(
                    "[E2eSync] state=request_failed \(PrivacySafeLogMetadata.errorFields(error))",
                    subsystems: .mls
                )
                self.sessionProgress.markPartial()
                self.syncNextInitialBatchOrFinish()
            case .success(let payload):
                guard let accountId = self.mlsClient.userId else {
                    log.error("[E2eSync] Discarding response without an active account", subsystems: .mls)
                    self.finishSync()
                    return
                }
                var nextCursors: [String: ScopeSyncCursorPayload] = [:]
                var failedScopes: Set<String> = []
                var retryCursors: [String: ScopeSyncCursorPayload] = [:]
                var nextRetries = materializationRetries

                for (cidString, channelPayload) in payload.channels {
                    guard let cid = try? ChannelId(cid: cidString) else {
                        self.sessionProgress.markPartial()
                        failedScopes.insert(cidString)
                        log.error("[E2eSync] state=invalid_scope_cid", subsystems: .mls)
                        continue
                    }

                    do {
                        for event in channelPayload.events {
                            if case .protocol = event.event {
                                log.info("mls_scope_trace stage=protocol_received cid=\(cidString) event_id=\(event.eventId) created_at=\(event.createdAtRaw)", subsystems: .mls)
                            }
                        }
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
                            if let owner = self.bootstrapOwnerStamp() {
                                try? self.mlsClient.removeRecoveryCheckpoint(key: self.initialJoinSyncKey(cidString, owner: owner))
                            }
                        }
                        self.processE2eSyncEvents(
                            persisted.insertedEvents,
                            cid: cid,
                            cidString: cidString
                        )
                        if !channelPayload.hasMore {
                            self.syncLock.lock()
                            if self.successfulSyncScopes.insert(cidString).inserted {
                                self.pendingSyncReadinessScopes.insert(cidString)
                            }
                            self.successfulSyncDemand[cidString] = requestedDemands[cidString]
                            self.syncLock.unlock()
                        }
                    } catch {
                        self.sessionProgress.markPartial()
                        failedScopes.insert(cidString)
                        let diagnosticId: String?
                        if case E2eeDurableInboxError.duplicateEventPayloadMismatch(let eventId) = error {
                            diagnosticId = eventId
                        } else {
                            diagnosticId = channelPayload.events.first?.eventId
                        }
                        if let diagnosticId {
                            MlsIncomingTrace.record(.scopePageFailed, uuid: diagnosticId, ciphertext: nil, error: error)
                        }
                        if case .invalidPagination = error as? E2eeDurableInboxError,
                           channelPayload.nextCursor != nil,
                           let original = cursors[cidString],
                           (materializationRetries[cidString] ?? 0) < 3 {
                            retryCursors[cidString] = original
                            nextRetries[cidString] = (materializationRetries[cidString] ?? 0) + 1
                            log.warning("[E2eSync] state=page_materialization_pending action=retry_same_cursor", subsystems: .mls)
                            continue
                        }
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
                        self.syncLock.lock()
                        self.successfulSyncScopes.removeAll(); self.pendingSyncReadinessScopes.removeAll()
                        self.syncLock.unlock()
                        log.error(
                            "[E2eSync] state=removed_cleanup_blocked "
                                + PrivacySafeLogMetadata.errorFields(error),
                            subsystems: .mls
                        )
                        self.finishSync()
                    case .success(let removedHasMore):
                        if !removedHasMore { self.publishCompletedSyncScopes(owner: owner) }
                        var remaining = retryCursors
                        for (cid, ch) in payload.channels where ch.hasMore && !failedScopes.contains(cid) {
                            if let next = nextCursors[cid] {
                                remaining[cid] = next
                            }
                        }
                        if !remaining.isEmpty || removedHasMore {
                            log.debug("[E2eSync] Paginating for \(remaining.count) scope(s)\(removedHasMore ? " + removed_channels" : "")", subsystems: .mls)
                            if retryCursors.isEmpty {
                                self.syncPage(cursors: remaining, materializationRetries: nextRetries)
                            } else {
                                let retryPage = remaining
                                let retryCounts = nextRetries
                                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                                    guard let self, self.sessionProgress.owns(owner), self.mlsClient.userId == accountId else { return }
                                    self.syncLock.lock()
                                    let stillSyncing = self.isSyncing
                                    self.syncLock.unlock()
                                    guard stillSyncing else { return }
                                    self.syncPage(cursors: retryPage, materializationRetries: retryCounts)
                                }
                            }
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
    func handleRemovedChannels(
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
                var removalBoundaries: [String: ScopeSyncCursorPayload] = [:]

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
                        log.info("mls_scope_trace stage=removed_ignored cid=\(cidString) event_id=\(event.eventId ?? Self.zeroEventId) created_at=\(event.removedAt ?? "invalid")", subsystems: .mls)
                        log.debug(
                            "[E2eSync] state=removal_skipped reason=rejoined removal_type=\(event.removalType ?? "unknown")",
                            subsystems: .mls
                        )
                        continue
                    }

                    guard let removedAt = event.removedAt, Self.parseRemovedAt(removedAt) != nil else {
                        throw E2eeDurableInboxError.invalidRemovedPagination
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
                    // This stream is ordered. Keep the last removal for this scope, never the
                    // global removal-page tail (which can belong to a different channel).
                    // Zero UUID conservatively replays the removal timestamp bucket.
                    removalBoundaries[cidString] = .init(createdAt: removedAt, eventId: Self.zeroEventId)
                    log.info("mls_scope_trace stage=removed_cleanup cid=\(cidString) event_id=\(event.eventId ?? Self.zeroEventId) created_at=\(removedAt)", subsystems: .mls)
                }

                // Core Data cleanup and removed-cursor advancement are atomic. If this throws,
                // already-deleted MLS groups remain safe because deletion is idempotent and the
                // unchanged server cursor will replay this page.
                try self.durableInboxStore.commitRemovedPage(
                    accountId: accountId,
                    channelCids: channelCids,
                    scopeCids: cleanedScopeCids,
                    removalBoundaries: removalBoundaries,
                    nextCursor: nextCursor
                )

                self.durableApplyLock.lock()
                self.blockedDurableScopes.subtract(cleanedScopeCids)
                self.durableApplyLock.unlock()

                // Rollback-only mirrors for app versions predating the durable checkpoint.
                self.saveSyncCursors(removalBoundaries)
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
            finishSessionDelta()
            return
        }

        finishSyncAfterDurableTurns(cids, owner: sessionProgress.owner)
    }

    private func finishSyncAfterDurableTurns(_ cids: Set<String>, owner: UUID) {
        // A drain deliberately yields every 100 envelopes. Its next turn can be queued
        // behind this barrier, so one barrier alone does not prove the durable prefix
        // has settled. Continue behind real queued turns, never a timer or network poll.
        let barrier = BlockOperation { [weak self] in
            guard let self, self.sessionProgress.owns(owner), let accountId = self.mlsClient.userId else { return }
            self.durableApplyLock.lock()
            let pending = cids.filter { self.scheduledDurableDrains.contains("\(accountId)|\($0)") }
            self.durableApplyLock.unlock()
            if pending.isEmpty {
                self.finishSessionDelta()
            } else {
                self.finishSyncAfterDurableTurns(pending, owner: owner)
            }
        }
        barrier.queuePriority = .low
        enqueueGroupOperation(barrier, cidStrings: cids)
    }

    /// The last successful page and this scope's durable drain establish its
    /// live-sync proof independently of other scopes. Queue admission remains
    /// owned by the original batch until its normal completion.
    private func publishCompletedSyncScopes(owner: UUID) {
        syncLock.lock()
        let cids = pendingSyncReadinessScopes
        pendingSyncReadinessScopes.removeAll()
        let work = syncProgressTicket?.work
        syncLock.unlock()
        guard let work else { return }
        for raw in cids {
            readinessLock.lock(); let dormant = dormantBootstrapScopes.contains(raw); readinessLock.unlock()
            if dormant { continue }
            guard let cid = try? ChannelId(cid: raw) else { continue }
            afterBootstrapDurableTurns(cid) { [weak self] in
                guard let self, self.sessionProgress.owns(owner) else { return }
                // The existing serialized provider turn also orders this check
                // before batch completion/replacement; old tickets cannot publish.
                self.syncLock.lock()
                let current = self.isSyncing && self.syncProgressTicket?.work == work
                    && self.successfulSyncScopes.contains(raw)
                if current { self.unverifiedLiveSyncScopes.remove(raw) }
                self.syncLock.unlock()
                guard current, self.bootstrapCompletionState(for: cid) == .ready else { return }
                self.setReadiness(.ready, for: raw)
            }
        }
    }

    private func finishSessionDelta() {
        syncLock.lock()
        let include = syncIncludesStandard
        if include && standardSyncFinishing { syncLock.unlock(); return }
        if include { standardSyncFinishing = true }
        syncLock.unlock()
        completeSyncRun()
    }

    private func completeSyncRun() {
        let owner = sessionProgress.owner
        syncLock.lock()
        let completedCids = activeSyncCids
        let delivered = successfulSyncScopes, deliveredDemands = successfulSyncDemand
        let memberships = activeSyncMembershipDates
        activeSyncMembershipDates.removeAll()
        successfulSyncDemand.removeAll()
        unverifiedLiveSyncScopes.subtract(successfulSyncScopes)
        successfulSyncScopes.removeAll()
        pendingSyncReadinessScopes.removeAll()
        let progressTicket = syncProgressTicket
        syncProgressTicket = nil
        isSyncing = false
        syncIncludesStandard = false
        standardSyncFinishing = false
        activeSyncCids.removeAll()
        let completions = activeSyncCompletions
        activeSyncCompletions.removeAll()
        pendingInitialSyncCursorBatches.removeAll()
        // Same-demand duplicate notifications are already represented by this
        // successful durable delivery. New demand or failed transport keeps the
        // normal trailing run; this does not publish messaging readiness.
        let pending = pendingSyncCompletions.isEmpty ? Set(pendingChannelSyncCids.filter {
            !delivered.contains($0) || deliveredDemands[$0] != scopeSyncDemand[$0]?.id
        }) : pendingChannelSyncCids
        pendingChannelSyncCids.removeAll()
        let pendingCompletions = pendingSyncCompletions
        pendingSyncCompletions.removeAll()
        syncLock.unlock()

        let now = ProcessInfo.processInfo.systemUptime
        let coverage = delivered.compactMap { cid -> (String, LiveSyncCoverage)? in
            guard let demand = deliveredDemands[cid] else { return nil }
            return (cid, LiveSyncCoverage(completedAt: now, demand: demand,
                marker: mlsClient.loadGenerationMarker(cid: cid), membershipDate: memberships[cid]))
        }
        syncLock.lock()
        if sessionProgress.owns(owner), !isSyncing {
            for (cid, witness) in coverage { liveSyncCoverage[cid] = witness }
        }
        syncLock.unlock()

        if let progressTicket { sessionProgress.end(progressTicket, retry: { [weak self] in self?.performE2eSync(trigger: "progress_retry") }) }
        completions.forEach { $0() }
        for cidString in completedCids {
            if let cid = try? ChannelId(cid: cidString) { recoverSkippedCaptionUpdates(in: cid) }
            // A prior binary may have retained same-epoch applications behind
            // the old generation's merged join receipt. Re-evaluate those rows
            // only after this real scope invocation proves an installed Welcome.
            if let cid = try? ChannelId(cid: cidString),
               (try? installedGenerationWelcomeBoundary(for: cidString)) != nil {
                retryPendingGroupApplications(in: cid)
            }
            membershipRequestLock.lock()
            let due = Date().timeIntervalSince(membershipLastAttempt[cidString] ?? .distantPast) >= 30
            membershipRequestLock.unlock()
            if due, let cid = try? ChannelId(cid: cidString) {
                _ = try? resumeMembershipMutation(cid: cid, completion: { _ in })
            }
        }

        guard !pending.isEmpty else { return }
        log.debug("[E2eSync] Draining \(pending.count) queued channel sync(s)", subsystems: .mls)
        runSync(forCidStrings: pending, completion: {
            pendingCompletions.forEach { $0() }
        })
    }

    /// Old clients acknowledged unknown caption events; merely fetching after their cursor
    /// cannot rediscover the missing cache. Repair retained, current versions after catch-up.
    private func recoverSkippedCaptionUpdates(in cid: ChannelId) {
        let groupCid = mlsGroupCid(for: cid).rawValue
        let assertOwner = captureRetainedHistoryOwner()
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            do {
                try assertOwner()
                guard let accountId = self.mlsClient.userId else { return }
                let events = try self.durableInboxStore.skippedCaptionUpdates(accountId: accountId, scopeCid: groupCid)
                for event in events {
                    guard case .messageUpdated(let update) = event.event,
                          let bytes = update.message.encryptedData,
                          update.message.groupGeneration == self.groupGeneration(for: cid) else { continue }
                    do {
                        try assertOwner()
                        do {
                            try self.reDecryptUpdatedMessageSync(messageId: update.message.id, encryptedData: Data(bytes),
                                cid: cid, receiveSource: .scopeSync, expectedEnvelope: update.message.e2eeReceivedEnvelope)
                        } catch {
                            // Later Android sends can age a skipped edit out of the live receiver
                            // ratchet. Use only our existing device-local epoch checkpoint; verify
                            // membership/AAD and publish cache without changing provider or cursors.
                            guard let epoch = update.message.mlsEpoch.flatMap(UInt64.init(exactly:)),
                                  let local = try self.archiveRecovery?.localCheckpoint(cid: groupCid,
                                      generation: UInt64(update.message.groupGeneration), epoch: epoch) else {
                                MlsIncomingTrace.record(.captionCheckpointMissing, uuid: update.message.id,
                                    ciphertext: Data(bytes))
                                throw error
                            }
                            var archive = local.archive
                            defer { archive.resetBytes(in: 0..<archive.count) }
                            let recovered = try self.mlsClient.decryptArchivedApplication(cid: groupCid,
                                generation: UInt64(update.message.groupGeneration), archive: archive,
                                snapshot: local.snapshot, ciphertext: Data(bytes))
                            let members = try JSONDecoder().decode(E2eeArchiveWire.self, from: local.snapshot)["members"].array
                            guard recovered.epoch == epoch, members.contains(where: {
                                $0["leaf_index"].number == UInt64(recovered.senderIndex)
                                    && $0["user_id"].string == update.message.user.id
                            }) else { throw E2eeArchiveError.invalidData }
                            let payload = try self.validatedPayload(recovered.payload, processedAAD: recovered.aad,
                                messageId: update.message.id, cid: cid, expectedEnvelope: update.message.e2eeReceivedEnvelope)
                            try assertOwner()
                            try self.database.writeAndWait { session in
                                guard let row = session.message(id: update.message.id), row.encryptedData == Data(bytes),
                                      row.channel?.cid == cid.rawValue else { throw E2eeArchiveError.invalidData }
                                try session.saveMessageDecrypt(payload: payload, messageId: row.id,
                                    ciphertextHash: Data(SHA256.hash(data: Data(bytes))))
                                row.text = payload.text
                            }
                            self.e2eeAttachmentReceiveCoordinator.hydratePreviews(payload: payload,
                                messageId: update.message.id, cid: cid, source: .replayRecovery)
                            MlsIncomingTrace.record(.captionCheckpointRestored, uuid: update.message.id,
                                ciphertext: Data(bytes))
                        }
                        try assertOwner()
                        try self.durableInboxStore.markSkippedCaptionUpdateRepaired(accountId: accountId,
                            scopeCid: groupCid, envelope: event)
                    } catch {
                        MlsIncomingTrace.record(.decryptFailed, uuid: update.message.id, ciphertext: Data(bytes), error: error)
                    }
                }

            } catch {
                log.error("[E2eSync] state=caption_repair_failed " + PrivacySafeLogMetadata.errorFields(error), subsystems: .mls)
            }
        }
        operation.queuePriority = .low
        enqueueGroupOperation(operation, cidString: groupCid)
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
                var attempts = 0
                var observedPredecessors = Set<String>()
                while attempts < 100 {
                    let events = try self.durableInboxStore.loadPendingPrefix(
                        accountId: accountId, scopeCid: cidString, limit: 100 - attempts
                    )
                    guard !events.isEmpty else { return }
                    var prefixChanged = false
                    for event in events {
                        attempts += 1
                        switch self.applyDurableEvent(event, accountId: accountId, cid: cid, cidString: cidString) {
                        case .applied: break
                        case .blocked: return
                        case .prefixChanged(let predecessor):
                            // A WS event may have been read just before an HTTP page inserts
                            // its older predecessor. Reload that durable prefix, never retry
                            // native bytes out of order or classify this race as bad protocol.
                            guard observedPredecessors.insert(predecessor).inserted else {
                                throw E2eeDurableInboxError.outOfOrderApply(expectedEventId: predecessor, actualEventId: event.eventId)
                            }
                            prefixChanged = true
                        }
                        if prefixChanged { break }
                    }
                    if prefixChanged { continue }
                    scheduleNext = true
                    return
                }
                scheduleNext = true // Existing continuation yields after at most100 attempts.
            } catch {
                scheduleNext = false
                self.blockDurableScope(cidString, eventId: nil, error: error)
            }
        }
        op.queuePriority = .low
        enqueueGroupOperation(op, cidString: mlsGroupCid(for: cid).rawValue)
    }

    private enum DurableApplyOutcome {
        case applied
        case blocked
        case prefixChanged(String)
    }

    /// A changed prefix is retried locally; genuine protocol failure blocks that prefix.
    /// Metadata and application repairs keep
    /// the exact cursor moving after their repair row is durable; they never change send safety.
    private func applyDurableEvent(
        _ event: E2eSyncEventEnvelope,
        accountId: String,
        cid: ChannelId,
        cidString: String
    ) -> DurableApplyOutcome {
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
            case .preJoinEncryptedUpdate(let generation):
                try durableInboxStore.markApplied(accountId: accountId, scopeCid: cidString,
                    envelope: event, preJoinEncryptedUpdateGeneration: generation)
                log.info("[MLS] application_checkpoint stage=scope_cursor_saved result=committed", subsystems: .mls)
            case .requiresCursorAdvance:
                try durableInboxStore.markApplied(accountId: accountId, scopeCid: cidString, envelope: event,
                    installedWelcomeDeviceId: mlsClient.currentDeviceId)
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
                reDecryptPendingMessages(in: cid)
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
            return .applied
        } catch {
            if case let E2eeDurableInboxError.outOfOrderApply(expected, actual) = error,
               expected != actual {
                return .prefixChanged(expected)
            }
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
                    return .applied
                } catch {
                    self.blockDurableScope(cidString, eventId: event.eventId, error: error)
                    return .blocked
                }
            }
            blockDurableScope(cidString, eventId: event.eventId, error: error)
            return .blocked
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
        if let eventId { MlsIncomingTrace.record(.scopeBlocked, uuid: eventId, ciphertext: nil, error: error) }
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
                        // Historical recovery is scheduled only for an explicitly queried page.
                        try self.durableInboxStore.markApplicationDispositionAndApplied(
                            accountId: accountId,
                            scopeCid: cidString,
                            envelope: event,
                            disposition: applicationDisposition
                        )
                    } else if case .preJoinEncryptedUpdate(let generation) = disposition {
                        try self.durableInboxStore.markApplied(accountId: accountId, scopeCid: cidString,
                            envelope: event, preJoinEncryptedUpdateGeneration: generation)
                    } else if case .requiresCursorAdvance = disposition {
                        try self.durableInboxStore.markApplied(
                            accountId: accountId,
                            scopeCid: cidString,
                            envelope: event,
                            installedWelcomeDeviceId: self.mlsClient.currentDeviceId
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
                            // Retain the placeholder; a queried page owns archive demand.
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
            readinessLock.lock(); dormantBootstrapScopes.remove(cidString); readinessLock.unlock()
            return try applyE2eSyncProtocolEvent(
                data,
                accountId: accountId,
                eventId: envelope.eventId,
                envelope: envelope,
                cidString: cidString
            )
        case .application(let data):
            if !data.isSystemMessage { readinessLock.lock(); dormantBootstrapScopes.remove(cidString); readinessLock.unlock() }
            if data.isSystemMessage {
                handleSystemMessage(data, cid: cid)
            } else {
                let effectiveCid = mlsGroupCid(for: cid)
                let localGeneration = Int(
                    mlsClient.loadGenerationMarker(cid: effectiveCid.rawValue)?.generation ?? 0
                )
                if data.groupGeneration < localGeneration {
                    guard let cipher = data.mlsCiphertext else { throw E2eeSyncApplyError.missingCiphertext(messageId: data.id) }
                    do {
                        _ = try retainedHistoricalPayload(messageId: data.id, encryptedData: Data(cipher), cid: cid,
                            generation: data.groupGeneration, expectedEnvelope: data.e2eeReceivedEnvelope)
                        return .application(.decrypted)
                    } catch {
                        // Missing historical secrets cannot authorize current-provider decrypt
                        // or block eligible current-generation work in this scope.
                        return .application(.preJoinHistorical)
                    }
                }
                if data.groupGeneration > localGeneration {
                    enqueueBootstrap(for: effectiveCid)
                    return .application(.pendingGroup)
                }
                let firstDecryptableEpoch = firstDecryptableEpoch(for: effectiveCid)
                let welcomeBoundary = try installedGenerationWelcomeBoundary(for: cidString)
                let joinBoundary = try welcomeBoundary ?? durableInboxStore.localJoinBoundary(
                    accountId: accountId,
                    scopeCid: cidString
                )
                let awaitingBoundary = try durableInboxStore.localJoinReceiptProof(
                    accountId: accountId,
                    scopeCid: cidString
                )?.status == .merged && joinBoundary == nil && welcomeBoundary == nil
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
            guard data.cid == nil || data.cid == cid else { throw E2eeArchiveError.invalidData }
            let generation = Int(mlsClient.loadGenerationMarker(cid: mlsGroupCid(for: cid).rawValue)?.generation ?? 0)
            if try durableInboxStore.isPreJoinEncryptedUpdate(accountId: accountId, scopeCid: cidString,
                envelope: envelope, generation: generation) {
                return .preJoinEncryptedUpdate(generation: generation)
            }
            try handleMessageUpdatedSyncEvent(data, cid: cid)
        case .messagePin(let data):
            try handleMessagePinSyncEvent(data, cid: cid)
        case .memberRemoved(let data, let createdAt):
            log.info(
                "mls_membership_trace stage=removed event_id=\(envelope.eventId) created_at_ms=\(Int64(createdAt.timeIntervalSince1970 * 1000)) "
                    + "self_remove=\(data.selfRemove) target_user=\(data.memberContainer.member?.userId ?? "none")",
                subsystems: .mls
            )
            log.info(
                "[MLS] state=membership_event_received source=scope_sync event_id=\(envelope.eventId) "
                    + "created_at=\(createdAt.timeIntervalSince1970) self_remove=\(data.selfRemove) "
                    + "target_user=\(data.memberContainer.member?.userId ?? "missing")",
                subsystems: .mls
            )
            try handleMemberRemovedSyncEvent(data, cid: cid, removedAt: createdAt)
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
        // Receipt/drain work can hold the serialized MLS executor while a main
        // callback waits for that executor. Read committed metadata off the UI queue.
        e2eReadContext.performAndWait {
            epoch = ChannelDTO.load(cid: cid, context: e2eReadContext)?
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
        let assertOwner = captureRetainedHistoryOwner()
        let operation = BlockOperation { [weak self] in
            guard let self, (try? assertOwner()) != nil else { return }
            let current = self.groupGeneration(for: cid)
            var retained: [(String, Data, Int)] = []
            self.e2eReadContext.performAndWait {
                for id in uniqueMessageIds.prefix(100) {
                    guard let row = self.e2eReadContext.message(id: id), let bytes = row.encryptedData,
                          row.decryptedMessage == nil, row.mlsGroupGeneration < current else { continue }
                    retained.append((id, bytes, Int(row.mlsGroupGeneration)))
                }
            }
            for (id, bytes, generation) in retained {
                guard (try? assertOwner()) != nil else { return }
                _ = try? self.retainedHistoricalPayload(messageId: id, encryptedData: bytes, cid: cid, generation: generation)
            }
        }
        operation.queuePriority = .high
        enqueueGroupOperation(operation, cidString: mlsGroupCid(for: cid).rawValue)
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
                let welcomeBoundary = try self.installedGenerationWelcomeBoundary(for: scopeCid)
                let boundary = try welcomeBoundary ?? self.durableInboxStore.localJoinBoundary(
                    accountId: accountId,
                    scopeCid: scopeCid
                )
                let awaitingBoundary = try self.durableInboxStore.localJoinReceiptProof(
                    accountId: accountId,
                    scopeCid: scopeCid
                )?.status == .merged && boundary == nil && welcomeBoundary == nil
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

        if isObsoleteMemberRemoval(cid: event.cid, userId: targetUserId, removedAt: event.createdAt) {
            log.debug("[MLS] state=member_removed_ignored reason=newer_membership source=scope_websocket", subsystems: .mls)
            return
        }

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

            // Sync only records the ghost. A future membership mutation may bundle it.
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
    func handleMessageUpdatedSyncEvent(_ data: MessageUpdatedSyncData, cid: ChannelId) throws {
        try performMlsMutation(cidString: mlsGroupCid(for: cid).rawValue) {
            try self.applyMessageUpdatedSyncEvent(data, cid: cid)
        }
    }

    private func applyMessageUpdatedSyncEvent(_ data: MessageUpdatedSyncData, cid: ChannelId) throws {
        let messageId = data.message.id
        guard data.cid == nil || data.cid == cid else { throw E2eeArchiveError.invalidData }
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
            try reDecryptUpdatedMessageSync(
                messageId: messageId,
                encryptedData: encryptedData,
                cid: cid,
                receiveSource: .scopeSync,
                expectedEnvelope: data.message.e2eeReceivedEnvelope
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
    private func handleMemberRemovedSyncEvent(_ data: MemberRemovedSyncData, cid: ChannelId, removedAt: Date) throws {
        guard let member = data.memberContainer.member else {
            throw E2eeSyncApplyError.missingMember
        }

        let userId = member.userId
        let cidString = cid.rawValue

        if isObsoleteMemberRemoval(cid: cid, userId: userId, removedAt: removedAt) {
            log.debug("[MLS] state=member_removed_ignored reason=newer_membership source=scope_sync", subsystems: .mls)
            return
        }

        if userId == mlsClient.userId {
            retireInventoryChannel(cid)
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

            // Sync records the ghost only; it never submits a drain-only commit.
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
        // This event is already in the ordered sync being applied. Unlike a new
        // realtime wakeup it cannot request another read of that same transport.
        let bootstrapping = bootstrapQueue.contains(mlsGroupCid(for: cid))
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
        MlsIncomingTrace.record(.decryptStarted, uuid: messageId, ciphertext: encryptedData)
        let presentation = database.persistentStoreCoordinator.encryptedMessageStates
        let key = EncryptedMessageStateStore.Key(cid: cid.rawValue, id: messageId, ciphertext: encryptedData)
        var nativeAtExpectedEpoch = false
        do {
            let result = try decryptMessagePayloadBody(messageId: messageId, encryptedData: encryptedData,
                cid: cid, receiveSource: receiveSource, expectedEnvelope: expectedEnvelope,
                beforeNative: { localEpoch, messageEpoch in
                    nativeAtExpectedEpoch = messageEpoch.map { $0 >= 0 && UInt64($0) == localEpoch } ?? false
                    if nativeAtExpectedEpoch { presentation.begin(key) }
                })
            presentation.set(.encrypted, for: key)
            return result
        } catch {
            let state = EncryptedMessageFailurePresentation.state(for: error, nativeAtExpectedEpoch: nativeAtExpectedEpoch)
            presentation.set(state, for: key)
            MlsIncomingTrace.record(.decryptFailed, uuid: messageId, ciphertext: encryptedData, error: error)
            throw error
        }
    }

    private func decryptMessagePayloadBody(
        messageId: MessageId, encryptedData: Data, cid: ChannelId,
        receiveSource: E2eeAttachmentReceiveSource,
        expectedEnvelope: E2eeReceivedMessageEnvelope?,
        beforeNative: (UInt64, Int64?) -> Void
    ) throws -> E2ePayload {
        // Re-check the DB cache — a prior operation may have populated it.
        // Read on the background read-only context so the decrypt hot path never
        // hops to (and blocks on) the main-queue `viewContext`, and never on
        // `backgroundReadOnlyContext` (which a synchronous send may be blocking).
        var cachedPayload: E2ePayload?
        var cachedCiphertextHash: Data?
        var messageEpoch: Int64?
        let readContext = e2eReadContext
        readContext.performAndWait {
            messageEpoch = MessageDTO.load(id: messageId, context: readContext)?.mlsEpoch
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
                beforeNative(group.epoch(), messageEpoch)
                let processed = try mlsClient.processApplicationMessage(data: encryptedData, in: group)
                MlsIncomingTrace.record(.decryptSucceeded, uuid: messageId, ciphertext: encryptedData)
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
        beforeNative(group.epoch(), messageEpoch)
        log.debug("[MLS] Current group epoch: \(group.epoch())", subsystems: .mls)
        let processed = try mlsClient.processApplicationMessage(data: encryptedData, in: group)
        MlsIncomingTrace.record(.decryptSucceeded, uuid: messageId, ciphertext: encryptedData)
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
        let scope = mlsGroupCid(for: cid)
        let assertOwner = captureRetainedHistoryOwner()
        var pending: [(id: MessageId, data: Data, cid: ChannelId)] = []
        let firstEpoch = firstDecryptableEpoch(for: scope)
        context.performAndWait {
            let request = NSFetchRequest<MessageDTO>(entityName: MessageDTO.entityName)
            if let firstEpoch {
                request.predicate = NSPredicate(
                    format: "(cid == %@ OR channel.e2eeGroupId == %@ OR channel.parentcid == %@) AND encryptedData != nil AND decryptedMessage == nil AND mlsEpoch >= %lld",
                    scope.rawValue, scope.rawValue, scope.rawValue,
                    firstEpoch
                )
            } else {
                request.predicate = NSPredicate(
                    format: "(cid == %@ OR channel.e2eeGroupId == %@ OR channel.parentcid == %@) AND encryptedData != nil AND decryptedMessage == nil",
                    scope.rawValue, scope.rawValue, scope.rawValue
                )
            }
            request.sortDescriptors = [NSSortDescriptor(keyPath: \MessageDTO.createdAt, ascending: true),
                NSSortDescriptor(keyPath: \MessageDTO.id, ascending: true)]
            guard let results = try? context.fetch(request) else { return }
            pending = results.compactMap { dto in
                guard let data = dto.encryptedData, let rawCid = dto.cid, let route = try? ChannelId(cid: rawCid),
                      dto.channel?.mlsGroupCid == scope.rawValue else { return nil }
                return (dto.id, data, route)
            }
        }
        guard !pending.isEmpty else { return }
        log.debug(
            "[MLS] state=pending_redecrypt_started message_count=\(pending.count) reason=epoch_advanced",
            subsystems: .mls
        )
        for item in pending {
            let op = BlockOperation { [weak self] in
                guard let self else { return }
                do { try assertOwner(); try self.receiveStoredRealtimeApplication(messageId: item.id,
                    encryptedData: item.data, cid: item.cid, assertOwner: assertOwner) }
                catch { log.error("[MLS] state=realtime_decrypt_failed action=retain_ciphertext "
                    + PrivacySafeLogMetadata.errorFields(error), subsystems: .mls) }
            }
            op.queuePriority = .low
            enqueueGroupOperation(op, cidString: scope.rawValue)
        }
    }

    private func applyE2eSyncProtocolEvent(
        _ data: E2eSyncProtocolData,
        accountId: String,
        eventId: String,
        envelope: E2eSyncEventEnvelope,
        cidString: String
    ) throws -> E2eeSyncApplyDisposition {
        let commitHash = data.commit.map { SHA256.hash(data: Data($0)).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "none"
        log.info(
            "mls_membership_trace stage=protocol event_id=\(eventId) epoch=\(data.epoch) "
                + "sender_user=\(data.user.userId) sender_device=\(data.deviceId ?? "none") commit_hash=\(commitHash)",
            subsystems: .mls
        )
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
                    if data.type == .externalCommit,
                       data.epoch >= 0,
                       let receipt = try durableInboxStore.localJoinReceiptProof(accountId: accountId, scopeCid: cidString),
                       receipt.epoch == UInt64(data.epoch), let commit = data.commit,
                       receipt.commitHash == Data(SHA256.hash(data: Data(commit))),
                       let pending = mlsClient.loadPendingGenerationJoin(cid: cidString),
                       pending.candidateFenceVersion == 1, pending.generation == incomingGeneration,
                       pending.epoch == UInt64(data.epoch) {
                        // The server can publish our exact commit before its receipt callback
                        // activates the isolated candidate. This is a current join obligation,
                        // not pre-join history. Keep the protocol prefix durable; the existing
                        // post-activation sync will verify/finalize it and retry applications.
                        throw E2eeSyncApplyError.invalidCommit(reason: "external_join_activation_pending")
                    }
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

                var group = try self.mlsClient.loadGroup(with: cidString)
                if try self.reconcileMembershipProtocolBeforeApply(cid: ChannelId(cid: cidString), epoch: data.epoch, commit: commitData) {
                        try durableInboxStore.markCommitStatePersisted(accountId: accountId, scopeCid: cidString,
                            eventId: eventId, ciphertextHash: ciphertextHash, targetEpoch: targetEpoch)
                        return .requiresCursorAdvance
                }
                group = try self.mlsClient.loadGroup(with: cidString)
                let localEpoch = group.epoch()
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
                    if data.type == .externalCommit, receiptMatches,
                       let deviceId = data.deviceId, deviceId == mlsClient.currentDeviceId,
                       mlsClient.loadPendingGenerationJoin(cid: cidString) == nil,
                       let marker = mlsClient.loadGenerationMarker(cid: cidString), marker.status == "active",
                       marker.generation == incomingGeneration,
                       (incomingGeneration == 0 || (marker.groupId != nil && marker.groupId == data.groupId.map { Data($0) })),
                       !mlsClient.hasNonOperationalGroup(cid: cidString) {
                        // The exact merged receipt proves our accepted candidate was installed.
                        // A later realtime Commit may advance that installed group before the
                        // first catch-up returns our join event. Preserve the original boundary
                        // and finalize through the same atomic cursor/receipt transaction; do
                        // not reapply the older Commit or treat other historical bytes as proof.
                        try durableInboxStore.markCommitProofPersisted(
                            accountId: accountId, scopeCid: cidString, eventId: eventId,
                            ciphertextHash: ciphertextHash, targetEpoch: targetEpoch
                        )
                        try durableInboxStore.markCommitStatePersisted(
                            accountId: accountId, scopeCid: cidString, eventId: eventId,
                            ciphertextHash: ciphertextHash, targetEpoch: targetEpoch
                        )
                        return .finalizeExternalJoin(
                            commitHash: ciphertextHash, epoch: targetEpoch,
                            deviceId: deviceId, requireReceipt: true
                        )
                    }
                    try self.markMembershipCanonicalPersisted(cid: ChannelId(cid: cidString), epoch: data.epoch, commit: commitData)
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
                    try self.markMembershipCanonicalPersisted(cid: ChannelId(cid: cidString), epoch: data.epoch, commit: commitData)
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
                    processed = try self.persistCanonicalMembershipProtocol(cid: ChannelId(cid: cidString),
                        group: group, epoch: data.epoch, commit: commitData, serverAcceptedAt: envelope.createdAt)
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
        // Other creator devices are optional; they cannot substitute for a
        // required recipient. Preserve this check before staging any Commit.
        let requiredRecipients = Set(targetUserIds).subtracting([mlsClient.userId].compactMap { $0 })
        apiClient.request(endpoint: .consumeKeyPackagesBatch(userIds: targetUserIds), completion: { result in
            switch result {
            case .success(let payload):
                let coveredRecipients = Set(payload.members.filter { !$0.keyPackages.isEmpty }.map(\.userId))
                guard requiredRecipients.isSubset(of: coveredRecipients) else {
                    completion(.failure(ClientError.Unexpected("Recipient KeyPackage inventory is incomplete")))
                    return
                }
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

    func prepareMembershipAdd(cid: ChannelId, targets: Set<String>, ghosts: [String], keyPackages: [KeyPackage]) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            let store = try self.mlsClient.membershipMutationStore()
            guard try store.load(cid: cid.rawValue) == nil else { throw ClientError.Unexpected("Resume staged membership mutation first") }
            let group = try self.mlsClient.loadGroup(with: cid.rawValue)
            try self.beginMembershipPreparation(store: store, cid: cid, action: "add", targets: targets, group: group)
            let bundle = try self.mlsClient.addMembersWithRemovals(in: cid.rawValue, removeUserIds: ghosts, addMembers: keyPackages)
            try self.membershipMutationStageHook("native_prepared")
            let record = MlsMembershipMutation(accountId: self.mlsClient.userId ?? "", cid: cid.rawValue, action: "add",
                targets: targets.sorted(), ghosts: ghosts.sorted(), groupId: group.groupId(), commit: bundle.0.commit,
                welcome: bundle.0.welcome ?? Data(), ratchetTree: bundle.1.toBytes(),
                groupInfo: try self.requireMembershipGroupInfo(bundle.0), epoch: bundle.2)
            try store.save(record)
            try store.finishIntent(cid: cid.rawValue)
            self.traceMembershipMutation(record, stage: "created")
        }
    }

    func prepareMembershipRemove(cid: ChannelId, targets: Set<String>, ghosts: [String]) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            let store = try self.mlsClient.membershipMutationStore()
            guard try store.load(cid: cid.rawValue) == nil else { throw ClientError.Unexpected("Resume staged membership mutation first") }
            let group = try self.mlsClient.loadGroup(with: cid.rawValue)
            try self.beginMembershipPreparation(store: store, cid: cid, action: "remove", targets: targets, group: group)
            let preparedGroup = try self.mlsClient.loadGroup(with: cid.rawValue)
            let bundle = try self.mlsClient.removeMembers(Array(targets.union(ghosts)), in: preparedGroup)
            try self.membershipMutationStageHook("native_prepared")
            let record = MlsMembershipMutation(accountId: self.mlsClient.userId ?? "", cid: cid.rawValue, action: "remove",
                targets: targets.sorted(), ghosts: ghosts.sorted(), groupId: group.groupId(), commit: bundle.commit,
                welcome: Data(), ratchetTree: Data(), groupInfo: try self.requireMembershipGroupInfo(bundle), epoch: Int(group.epoch()))
            try store.save(record)
            try store.finishIntent(cid: cid.rawValue)
            self.traceMembershipMutation(record, stage: "created")
        }
    }

    private func beginMembershipPreparation(store: MlsMembershipMutationStore, cid: ChannelId, action: String,
                                            targets: Set<String>, group: Group) throws {
        guard store.hasIntent(cid: cid.rawValue) || !group.hasPendingCommit() else {
            throw ClientError.Unexpected("MLS mutation pending; reconcile server ACK first")
        }
        let resuming = try store.begin(cid: cid.rawValue, action: action, targets: targets)
        if resuming, group.hasPendingCommit() {
            // No complete artifact existed, so this candidate was never submitted.
            try self.mlsClient.clearPendingCommit(in: cid)
        }
    }

    private func requireMembershipGroupInfo(_ bundle: CommitBundle) throws -> Data {
        guard let info = bundle.groupInfo, !info.isEmpty else { throw ClientError.Unexpected("Membership GroupInfo missing") }
        return info
    }

    private func traceMembershipMutation(_ record: MlsMembershipMutation, stage: String) {
        let hash = SHA256.hash(data: record.commit).prefix(6).map { String(format: "%02x", $0) }.joined()
        log.info("mls_membership_trace stage=\(stage) action=\(record.action) epoch=\(record.epoch) commit_hash=\(hash)", subsystems: .mls)
    }

    /// Returns false only when this channel has no staged logical membership operation.
    @discardableResult
    func resumeMembershipMutation(cid: ChannelId, action: String? = nil, targets: Set<String>? = nil,
                                  completion: @escaping (Error?) -> Void) throws -> Bool {
        let record = try performMlsMutation(cidString: cid.rawValue) {
            try self.mlsClient.membershipMutationStore().load(cid: cid.rawValue)
        }
        guard let record else { return false }
        guard (action == nil || action == record.action), (targets == nil || targets == Set(record.targets)) else {
            completion(ClientError.Unexpected("Another membership operation is pending"))
            return true
        }
        if record.canRebase == true, action != nil, targets != nil {
            try performMlsMutation(cidString: cid.rawValue) {
                let store = try self.mlsClient.membershipMutationStore()
                guard let current = try store.load(cid: cid.rawValue), current.commit == record.commit,
                      current.canRebase == true else { throw ClientError.Unexpected("Membership recovery state changed") }
                _ = try store.begin(cid: cid.rawValue, action: record.action, targets: Set(record.targets))
                try store.remove(cid: cid.rawValue)
            }
            traceMembershipMutation(record, stage: "revalidate_after_epoch_stale")
            // ChannelUpdater now fetches a complete roster before creating the replacement.
            return false
        }
        if record.needsEpochSync == true {
            completion(ClientError.Unexpected("Membership mutation requires canonical epoch sync"))
            // Sync completion may observe this record; only an explicit retry requests another sync.
            if action != nil, membershipMutationSender == nil { performE2eChannelSync(cid: cid) }
            return true
        }
        membershipRequestLock.lock()
        let inserted = membershipRequestsInFlight.insert(cid.rawValue).inserted
        membershipLastAttempt[cid.rawValue] = Date()
        membershipRequestLock.unlock()
        guard inserted else { completion(ClientError.Unexpected("Membership operation is already in flight")); return true }
        let settle: (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            var result = error
            if let error, Self.isMembershipEpochStale(error) {
                do { try self.markMembershipEpochStale(cid: cid) } catch { result = error }
            }
            if result == nil {
                do {
                    try self.performMlsMutation(cidString: cid.rawValue) {
                        guard self.mlsClient.userId == record.accountId else { throw ClientError.Unexpected("MLS account changed") }
                        let store = try self.mlsClient.membershipMutationStore()
                        if var current = try store.load(cid: cid.rawValue) {
                            guard current.commit == record.commit else { throw ClientError.Unexpected("MLS membership scope changed") }
                            current.acknowledged = true
                            try store.save(current)
                            self.traceMembershipMutation(current, stage: "ack")
                            try self.membershipMutationStageHook("acknowledged")
                            try self.finishAcceptedMembershipMutation(current)
                        }
                    }
                } catch { result = error }
            }
            self.membershipRequestLock.lock()
            self.membershipRequestsInFlight.remove(cid.rawValue)
            self.membershipRequestLock.unlock()
            let hash = SHA256.hash(data: record.commit).prefix(6).map { String(format: "%02x", $0) }.joined()
            log.info("mls_membership_trace stage=\(result == nil ? "settled" : "retained") action=\(record.action) epoch=\(record.epoch) commit_hash=\(hash)", subsystems: .mls)
            completion(result)
            if result != nil, self.membershipMutationSender == nil { self.performE2eChannelSync(cid: cid) }
        }
        if record.acknowledged { settle(nil); return true }
        if let sender = membershipMutationSender { sender(record, settle); return true }
        guard mlsClient.userId == record.accountId else { settle(ClientError.Unexpected("MLS account changed")); return true }
        let endpoint: Endpoint<EmptyResponse>
        if record.action == "add" {
            let body = AddMembersRequestBody(addMembers: record.targets, commit: record.commit, welcome: record.welcome,
                ratchetTree: record.ratchetTree, epoch: record.epoch, groupInfo: record.groupInfo)
            endpoint = .addMembers(cid: cid, userIds: Set(record.targets), mlsBody: body)
        } else {
            let body = RemoveMembersRequestBody(removeMembers: record.targets, selfRemove: false,
                commit: record.commit, epoch: record.epoch, groupInfo: record.groupInfo)
            endpoint = .removeMembers(cid: cid, userIds: Set(record.targets), mlsBody: body)
        }
        traceMembershipMutation(record, stage: "request")
        apiClient.request(endpoint: endpoint) { settle($0.error) }
        return true
    }

    private static func isMembershipEpochStale(_ error: Error) -> Bool {
        let api = (error as? ErmisApiError) ?? ((error as? ClientError)?.underlyingError as? ErmisApiError)
        guard let api, [400, 409].contains(api.httpStatusCode) else { return false }
        return api.message.hasPrefix("epoch_stale:")
    }

    func markMembershipEpochStale(cid: ChannelId) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            let store = try self.mlsClient.membershipMutationStore()
            guard var current = try store.load(cid: cid.rawValue), !current.acknowledged else { return }
            current.needsEpochSync = true
            try store.save(current)
            self.traceMembershipMutation(current, stage: "epoch_stale_sync_required")
        }
    }

    /// Called only for an envelope in the authoritative ordered protocol stream.
    /// Returns true for our own accepted candidate; other commits still require native apply.
    func reconcileMembershipProtocolBeforeApply(cid: ChannelId, epoch: Int, commit: Data) throws -> Bool {
        try performMlsMutation(cidString: cid.rawValue) {
            let store = try self.mlsClient.membershipMutationStore()
            let group = try self.mlsClient.loadGroup(with: cid.rawValue)
            guard var current = try store.load(cid: cid.rawValue), current.groupId == group.groupId(),
                  current.epoch + 1 == epoch else { return false }
            if current.commit == commit {
                current.acknowledged = true
                try store.save(current)
                try self.finishAcceptedMembershipMutation(current)
                return true
            }
            let hash = Data(SHA256.hash(data: commit))
            guard !current.acknowledged, current.supersededCommitHash == nil || current.supersededCommitHash == hash else {
                throw ClientError.Unexpected("Conflicting canonical membership proof")
            }
            current.needsEpochSync = true
            current.supersededCommitHash = hash
            try store.save(current)
            if group.hasPendingCommit() { try self.mlsClient.clearPendingCommit(in: cid) }
            self.traceMembershipMutation(current, stage: "competing_epoch")
            return false
        }
    }

    /// Preserve the original logical operation until its winning epoch is durable locally.
    func markMembershipCanonicalPersisted(cid: ChannelId, epoch: Int, commit: Data) throws {
        try performMlsMutation(cidString: cid.rawValue) {
            let store = try self.mlsClient.membershipMutationStore()
            guard var current = try store.load(cid: cid.rawValue), current.needsEpochSync == true,
                  current.epoch + 1 == epoch, current.supersededCommitHash == Data(SHA256.hash(data: commit)) else { return }
            let group = try self.mlsClient.loadGroup(with: cid.rawValue)
            guard group.groupId() == current.groupId, group.epoch() >= UInt64(epoch) else {
                throw ClientError.Unexpected("Canonical membership state not persisted")
            }
            current.canRebase = true
            try store.save(current)
        }
    }


    func persistCanonicalMembershipProtocol(cid: ChannelId, group: Group, epoch: Int, commit: Data,
                                            serverAcceptedAt: Date? = nil) throws -> MlsProcessedProtocolMessage {
        try performMlsMutation(cidString: cid.rawValue) {
            let processed: MlsProcessedProtocolMessage
            if let serverAcceptedAt {
                processed = try self.mlsClient.processProtocolMessage(data: commit, in: group, serverAcceptedAt: serverAcceptedAt)
            } else {
                processed = try self.mlsClient.processProtocolMessage(data: commit, in: group)
            }
            guard epoch > 0, case .commit(let metadata) = processed,
                  metadata.groupEpochAfter == UInt64(epoch), group.epoch() == UInt64(epoch) else {
                throw E2eeSyncApplyError.invalidCommit(reason: "Canonical membership commit did not reach target epoch")
            }
            try self.mlsClient.saveState(of: group)
            try self.markMembershipCanonicalPersisted(cid: cid, epoch: epoch, commit: commit)
            return processed
        }
    }

    private func finishAcceptedMembershipMutation(_ record: MlsMembershipMutation) throws {
        guard record.acknowledged, mlsClient.userId == record.accountId else { throw ClientError.Unexpected("Membership accepted proof missing") }
        let cid = try ChannelId(cid: record.cid)
        var group = try mlsClient.loadGroup(with: record.cid)
        guard group.groupId() == record.groupId else { throw ClientError.Unexpected("Membership group identity changed") }
        if group.hasPendingCommit() { try mlsClient.mergePendingCommit(in: cid) }
        group = try mlsClient.loadGroup(with: record.cid)
        guard Int(group.epoch()) == record.epoch + 1 else { throw ClientError.Unexpected("Membership epoch mismatch") }
        try mlsClient.saveState(of: group)
        try database.writeAndWait { session in
            for userId in record.ghosts where group.membersByUserId(userId: userId).isEmpty {
                session.deletePendingRemoveMember(userId: userId, channelCid: record.cid)
            }
        }
        try membershipMutationStageHook("merged")
        traceMembershipMutation(record, stage: "merged")
        try mlsClient.membershipMutationStore().remove(cid: record.cid)
    }

    static func hasNewerActiveMembership(
        memberCreatedAt: Date?, isJoined: Bool, removedAt: Date
    ) -> Bool {
        isJoined && (memberCreatedAt ?? .distantPast) > removedAt
    }

    /// A delayed removal cannot delete a group or queue a ghost after a newer re-add.
    private func isObsoleteMemberRemoval(cid: ChannelId, userId: String, removedAt: Date) -> Bool {
        var newerActiveMembership = false
        database.viewContext.performAndWait {
            let channel = ChannelDTO.load(cid: cid, context: database.viewContext)
            newerActiveMembership = channel?.members.contains(where: { member in
                member.user.userId == userId && Self.hasNewerActiveMembership(
                    memberCreatedAt: member.memberCreatedAt?.bridgeDate,
                    isJoined: member.isJoined || member.channelRoleRaw == MemberRole.pending.rawValue,
                    removedAt: removedAt
                )
            }) == true
        }
        return newerActiveMembership
    }

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

    // No product entry point currently exposes manual drain-only eviction.
    // Pending ghosts are resolved by the next verified composite add/remove.

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

    private struct GiPublicationJob: Codable {
        let identity: String
        let body: Data
        var attempts: Int
        var dueAt: Date
        var finished: Bool
    }
    private let giPublicationLock = NSLock()
    private var giPublicationsInFlight = Set<String>()
    private var giDiscoveryLastAt = Date.distantPast

    private func giPublicationKey(cid: String, scope: GroupInfoRepairScope) -> String {
        let owner = Data("\(scope.accountId):\(scope.deviceId):\(cid)".utf8)
        return "ermis_gi_publication_v1:" + SHA256.hash(data: owner).map { String(format: "%02x", $0) }.joined()
    }

    private func handleGroupInfoRefreshRequested(_ event: GroupInfoRefreshRequestedEvent) {
        reconcileGiPublication(cid: event.cid)
    }

    private func handleGroupInfoUploaded(_ event: GroupInfoUploadedEvent) {
        // Availability hints never activate MLS state or grant Ready.
    }

    private struct GiDiscoveryBody: Encodable { let protocol_version = 1; let cids: [String] }
    private struct GiDiscoveryResponse: Decodable {
        struct Item: Decodable { let result: String; let publication_marker: GiPublicationMarker? }
        let states: [String: Item]
    }

    private func reconcilePendingGroupInfoRepairs() {
        guard mlsRolloutControls.groupInfoRepairEnabled, let scope = groupInfoRepairScope else { return }
        giPublicationLock.lock()
        guard Date().timeIntervalSince(giDiscoveryLastAt) >= 30 else { giPublicationLock.unlock(); return }
        giDiscoveryLastAt = Date()
        giPublicationLock.unlock()
        // One bounded batch per page replaces all-group claim/lease scans.
        let cids = (try? mlsClient.getStoredGroupIdList()) ?? []
        for offset in stride(from: 0, to: cids.count, by: 20) {
            let body = GiDiscoveryBody(cids: Array(cids[offset..<min(offset + 20, cids.count)]))
            let endpoint = Endpoint<GiDiscoveryResponse>(path: .mlsControl("v1/e2ee/mls/recovery/discover"), method: .post, body: body, needDeviceId: true)
            apiClient.request(endpoint: endpoint) { [weak self] result in
                guard let self, self.groupInfoRepairScope == scope, case .success(let response) = result else { return }
                for (raw, item) in response.states where item.result == "state" {
                    guard let marker = item.publication_marker, let cid = try? ChannelId(cid: raw) else { continue }
                    self.publishGi(cid: cid, marker: marker, scope: scope)
                }
            }
        }
    }

    private func reconcileGiPublication(cid: ChannelId) {
        guard mlsRolloutControls.groupInfoRepairEnabled, let scope = groupInfoRepairScope else { return }
        apiClient.request(endpoint: .getGroupInfoRefresh(cid: cid)) { [weak self] result in
            guard let self, self.groupInfoRepairScope == scope,
                case .success(let response) = result, let marker = response.marker else { return }
            self.publishGi(cid: cid, marker: marker, scope: scope)
        }
    }

    private func publishGi(cid: ChannelId, marker: GiPublicationMarker, scope: GroupInfoRepairScope) {
        let identityOwner = mlsClient.identity
        let key = giPublicationKey(cid: cid.rawValue, scope: scope)
        giPublicationLock.lock()
        guard giPublicationsInFlight.insert(key).inserted else { giPublicationLock.unlock(); return }
        giPublicationLock.unlock()
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.giPublicationLock.lock(); self.giPublicationsInFlight.remove(key); self.giPublicationLock.unlock()
        }
        do {
            let target = mlsClient.loadGenerationMarker(cid: cid.rawValue)
            let body: UploadGroupInfoRequestBody = try performMlsMutation(cidString: cid.rawValue) {
                guard self.groupInfoRepairScope == scope, self.mlsClient.identity === identityOwner, self.mlsClient.loadPendingGenerationJoin(cid: cid.rawValue) == nil,
                    self.loadMlsRebootstrapCheckpoint(cid: cid.rawValue) == nil,
                    (target?.generation ?? 0) == marker.group_generation else { throw ClientError("GI publication owner changed") }
                let group = try self.mlsClient.loadGroup(with: cid.rawValue)
                guard group.isOperational(), !group.hasPendingCommit(), group.epoch() == marker.epoch else { throw ClientError("GI publication epoch changed") }
                let gi = try self.mlsClient.exportGroupInfo(of: group)
                guard !gi.isEmpty, gi.count <= 1_048_576 else { throw ClientError("Invalid GroupInfo size") }
                return UploadGroupInfoRequestBody(groupInfo: gi, epoch: Int(marker.epoch),
                    expected: GiPublicationTarget(groupGeneration: marker.group_generation, groupId: target?.groupId?.base64EncodedString()),
                    observedHash: marker.observed_hash)
            }
            guard let signer = identityOwner?.signaturePublicKey() else { finish(); return }
            let signerHash = SHA256.hash(data: signer).map { String(format: "%02x", $0) }.joined()
            let identity = "\(signerHash):\(marker.group_generation):\(marker.epoch):\(target?.groupId?.base64EncodedString() ?? ""):\(marker.observed_hash ?? "")"
            let stored = try mlsClient.readRecoveryCheckpoint(key: key)
            var job = try stored.map { try JSONDecoder().decode(GiPublicationJob.self, from: $0) }
            if job?.identity != identity { job = GiPublicationJob(identity: identity, body: try JSONEncoder.ermis.encode(body), attempts: 0, dueAt: .distantPast, finished: false) }
            guard var reserved = job, !reserved.finished, reserved.attempts < 3, reserved.dueAt <= Date() else { finish(); return }
            reserved.attempts += 1
            reserved.dueAt = Date().addingTimeInterval(pow(2, Double(reserved.attempts)))
            let saved = try JSONEncoder().encode(reserved)
            try mlsClient.writeRecoveryCheckpoint(saved, key: key)
            guard try mlsClient.readRecoveryCheckpoint(key: key) == saved, groupInfoRepairScope == scope,
                mlsClient.loadGenerationMarker(cid: cid.rawValue) == target else { finish(); return }
            let endpoint = Endpoint<ChannelPayload>(path: .uploadGroupInfo(cid), method: .post, body: reserved.body, needDeviceId: true)
            apiClient.request(endpoint: endpoint) { [weak self] result in
                defer { finish() }
                guard let self, self.groupInfoRepairScope == scope, self.mlsClient.identity === identityOwner,
                    self.mlsClient.loadGenerationMarker(cid: cid.rawValue) == target,
                    (try? self.mlsClient.readRecoveryCheckpoint(key: key)) == saved else { return }
                if case .success = result {
                    var settled = reserved; settled.finished = true
                    if let data = try? JSONEncoder().encode(settled) { try? self.mlsClient.writeRecoveryCheckpoint(data, key: key) }
                }
            }
        } catch { finish() }
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
            case .success:
                self.reconcileGiPublication(cid: cid)
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
                            guard requiresActiveMemberRecovery,
                                  let retained = try? self.mlsClient.loadGroup(with: cid.rawValue),
                                  (self.hasRetainedReplayBlock(cid.rawValue)
                                      && retained.epoch() < UInt64(groupInfo.epoch))
                                    || (self.mlsClient.hasNonOperationalGroup(cid: cid.rawValue)
                                        && retained.epoch() <= UInt64(groupInfo.epoch)) else {
                                throw ClientError.Unexpected("Retained recovery is not authorized.")
                            }
                            return try self.mlsClient.externalJoinIsolated(cid: cid.rawValue,
                                generation: UInt64(groupInfo.groupGeneration), groupInfo: groupInfo.groupInfo.data,
                                expectedGroupId: groupInfo.groupId.map { Data($0) })
                        }
                        guard !self.mlsClient.isGroupLoaded(cid: cid.rawValue) else { return nil }
                        return try self.mlsClient.externalJoinIsolated(cid: cid.rawValue,
                            generation: UInt64(groupInfo.groupGeneration), groupInfo: groupInfo.groupInfo.data,
                            expectedGroupId: groupInfo.groupId.map { Data($0) })
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
                    // External Join stages into an isolated provider. A loaded live group
                    // belongs to an independently accepted Welcome/recovery and must survive
                    // a candidate/discovery failure, including a Welcome queued at this boundary.
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

        if let marker = mlsClient.loadPendingGenerationJoin(cid: cid.rawValue), marker.externalJoinBody != nil {
            do {
                guard let candidate = try performMlsMutation(cidString: cid.rawValue, { try self.mlsClient.resumeExternalJoinCandidate(cid: cid.rawValue) }) else {
                    throw ClientError.Unexpected("External join checkpoint unavailable")
                }
                requestExternalJoin(to: cid, externalJoinResult: candidate, groupGeneration: Int(marker.generation), groupId: marker.groupId, completion: completion)
            } catch { completion(error) }
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
        case .prepared where mlsClient.loadPendingGenerationJoin(cid: cid.rawValue)?.externalJoinBody != nil:
            do {
                guard let marker = mlsClient.loadPendingGenerationJoin(cid: cid.rawValue),
                    let candidate = try performMlsMutation(cidString: cid.rawValue, { try self.mlsClient.resumeExternalJoinCandidate(cid: cid.rawValue) }) else {
                    throw ClientError.Unexpected("External join candidate unavailable")
                }
                requestExternalJoin(to: cid, externalJoinResult: candidate, groupGeneration: Int(marker.generation),
                    groupId: marker.groupId, completion: completion)
            } catch { completion(error) }
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
        let identityOwner = mlsClient.identity
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
            if let previous = try durableInboxStore.localJoinReceiptProof(accountId: accountId, scopeCid: cid.rawValue) {
                guard previous.epoch == targetEpoch, previous.commitHash == commitHash, previous.requestDeviceId == requestDeviceId else {
                    throw ClientError("External join local receipt changed")
                }
            } else {
            try durableInboxStore.prepareLocalJoinReceipt(
                accountId: accountId,
                scopeCid: cid.rawValue,
                epoch: targetEpoch,
                commitHash: commitHash,
                requestDeviceId: requestDeviceId
            )
            }
        } catch {
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
        let inlineGI: Data
        do { inlineGI = try performMlsMutation(cidString: cid.rawValue) { try self.mlsClient.exportGroupInfo(of: externalJoinResult.group) } }
        catch { completion(error); return }
        let body = ExternalJoinRequestBody(commit: externalJoinResult.commit,
                                           epoch: Int(targetEpoch),
                                           groupInfo: inlineGI,
                                           operationId: mlsClient.loadPendingGenerationJoin(cid: cid.rawValue)?.operationId ?? UUID().uuidString.lowercased(),
                                           groupGeneration: groupGeneration,
                                           groupId: groupId,
                                           projectId: cid.projectId)
        submitAtomicExternalJoin(cid: cid, body: body) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let acceptance):
                let acceptedCandidate = acceptance.candidate
                trace.info(
                    stage: "external_commit_accepted",
                    source: "external_join",
                    result: "accepted",
                    receipt: self.joinReceiptTraceStatus(for: cid.rawValue),
                    groupLoaded: self.mlsClient.isGroupLoaded(cid: cid.rawValue),
                    localEpoch: targetEpoch
                )
                do {
                    if try durableInboxStore.localJoinReceiptProof(accountId: accountId, scopeCid: cid.rawValue)?.status != .merged {
                    try durableInboxStore.markLocalJoinServerAccepted(
                        accountId: accountId,
                        scopeCid: cid.rawValue
                    )
                    }
                    let (groupInfo, epoch) = try performMlsMutation(cidString: cid.rawValue) {
                        guard self.mlsClient.userId == accountId, self.mlsClient.currentDeviceId == requestDeviceId,
                            self.mlsClient.identity === identityOwner else { throw ClientError("External join owner changed") }
                        try self.mlsClient.assertExternalJoinCandidateCurrent(cid: cid.rawValue)
                        if externalJoinResult.group.hasPendingCommit() { try self.mlsClient.mergePendingCommit(in: cid) }
                        let group = externalJoinResult.group
                        try self.mlsClient.activateExternalJoinCandidate(cid: cid.rawValue, expected: acceptedCandidate, group: group)
                        return (try self.mlsClient.exportGroupInfo(of: group), group.epoch())
                    }
                    try durableInboxStore.markLocalJoinMerged(
                        accountId: accountId,
                        scopeCid: cid.rawValue,
                        firstDecryptableEpoch: epoch
                    )
                    try performMlsMutation(cidString: cid.rawValue) {
                        try self.mlsClient.finishExternalJoinCandidate(cid: cid.rawValue, expected: acceptedCandidate)
                    }
                    let retainedWelcome = try durableInboxStore.hasNoMatchingKeyPackageJoinPrerequisite(
                        accountId: accountId, scopeCid: cid.rawValue
                    )
                    try durableInboxStore.clearNoMatchingKeyPackageJoinPrerequisite(
                        accountId: accountId,
                        scopeCid: cid.rawValue
                    )
                    if !retainedWelcome, self.isPristineJoinBase(acceptedCandidate),
                       let cursor = acceptance.initialCursor, let owner = self.bootstrapOwnerStamp(),
                       self.mlsClient.userId == accountId, self.mlsClient.currentDeviceId == requestDeviceId,
                       self.mlsClient.identity === identityOwner,
                       let marker = self.mlsClient.loadGenerationMarker(cid: cid.rawValue) {
                        let hint = InitialJoinSyncAnchor(owner: owner, cid: cid.rawValue, deviceId: requestDeviceId,
                            commitHash: commitHash, epoch: epoch, marker: marker, cursor: cursor)
                        // Optional optimization; a failed write retains the membership fallback.
                        if let bytes = try? JSONEncoder().encode(hint) {
                            try? self.mlsClient.writeRecoveryCheckpoint(bytes, key: self.initialJoinSyncKey(cid.rawValue, owner: owner))
                        }
                    }
                    normalizeHistoricalApplications(cid: cid)
                    trace.info(
                        stage: "external_commit_merged",
                        source: "external_join",
                        result: "group_info_accepted_inline",
                        receipt: "merged",
                        groupLoaded: true,
                        localEpoch: epoch
                    )
                    // GI was durably accepted with the commit; no second publication request.
                    _ = groupInfo
                    completion(nil)
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
    
    private struct InitialJoinSyncAnchor: Codable {
        let owner: Data
        let cid: String
        let deviceId: String
        let commitHash: Data
        let epoch: UInt64
        let marker: MlsClient.GroupGenerationMarker
        let cursor: ScopeSyncCursorPayload
    }

    private func initialJoinSyncKey(_ cid: String, owner: Data) -> String {
        "initial_join_sync_v1:" + SHA256.hash(data: owner).map { String(format: "%02x", $0) }.joined() + ":" + cid
    }

    private func isPristineJoinBase(_ candidate: MlsClient.GroupGenerationMarker) -> Bool {
        guard candidate.candidateFenceVersion == 1, candidate.candidateBaseEpoch == nil,
              let bytes = candidate.candidateBaseMarker else { return false }
        do { return try JSONDecoder().decode(MlsClient.GroupGenerationMarker?.self, from: bytes) == nil }
        catch { return false }
    }

    private typealias AtomicJoinAcceptance = (candidate: MlsClient.GroupGenerationMarker, initialCursor: ScopeSyncCursorPayload?)

    private struct AtomicJoinReceipt: Decodable {
        let version: Int
        let operation_id: String
        let cid: String
        let state: String
        let group_generation: UInt64?
        let epoch: UInt64?
        let group_id: String?
        let commit_sha256: String?
        let group_info_sha256: String?
        let event_id: String?
        let rejection_reason: String?
        let rejected_at: String?
        let acceptance_context: E2eeArchiveWire?

        var initialCursor: ScopeSyncCursorPayload? {
            guard let context = acceptance_context, let event = event_id, UUID(uuidString: event) != nil,
                  let generation = group_generation, let epoch, let digest = commit_sha256,
                  context["version"].number == 1, context["provenance"].string == "bellboy_transition_v1",
                  context["event_id"].string == event, context["cid"].string == cid,
                  context["group_generation"].number == generation, context["epoch"].number == epoch,
                  context["payload_sha256"].string == digest,
                  let second = context["accepted_at"].number, second > 0,
                  second <= UInt64(Int64.max / 1000), Double(second) <= Date().timeIntervalSince1970 + 300 else { return nil }
            return E2eRepository.cursor(fromMilliseconds: Int64(second) * 1000)
        }
    }

    private func submitAtomicExternalJoin(cid: ChannelId, body: ExternalJoinRequestBody,
        completion: @escaping (Result<AtomicJoinAcceptance, Error>) -> Void) {
        do {
            guard let account = mlsClient.userId, var marker = mlsClient.loadPendingGenerationJoin(cid: cid.rawValue) else {
                throw ClientError.Unexpected("Isolated external join checkpoint required")
            }
            let encoded = try marker.externalJoinBody ?? JSONEncoder.ermis.encode(body)
            guard let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                let operation = json["operation_id"] as? String, UUID(uuidString: operation) != nil,
                let commitString = json["commit"] as? String, let commit = Data(base64Encoded: commitString),
                let giString = json["group_info"] as? String, let gi = Data(base64Encoded: giString) else {
                throw ClientError.Unexpected("External join checkpoint invalid")
            }
            marker.externalJoinBody = encoded
            try mlsClient.savePendingGenerationJoin(marker)
            let identityOwner = mlsClient.identity, deviceOwner = mlsClient.currentDeviceId
            let frozen = marker
            let current: () throws -> Void = { [weak self] in
                guard let self, self.mlsClient.userId == account, self.mlsClient.currentDeviceId == deviceOwner,
                    self.mlsClient.identity === identityOwner,
                    self.mlsClient.loadPendingGenerationJoin(cid: cid.rawValue) == frozen else {
                    throw ClientError.Unexpected("External join owner changed")
                }
            }
            let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            let receiptEndpoint = Endpoint<AtomicJoinReceipt>(path: .mlsControl("v1/e2ee/channels/\(cid.apiPath)/external_join/operations/\(operation)"),
                method: .get, needDeviceId: true)
            log.info("session_join operation_id=\(operation.lowercased()) stage=receipt", subsystems: .mls)
            let settle: (Result<AtomicJoinReceipt, Error>) -> Void = { [weak self] result in
                do {
                    try current()
                    let receipt = try result.get()
                    guard receipt.version == 1, receipt.operation_id == operation, receipt.cid == cid.rawValue,
                        receipt.group_generation == frozen.generation, receipt.epoch == frozen.epoch,
                        receipt.commit_sha256 == hash(commit), receipt.group_info_sha256 == hash(gi),
                        receipt.group_id.flatMap({ Data(base64Encoded: $0) }) == (frozen.generation > 0 ? frozen.groupId : nil) else {
                        throw ClientError.Unexpected("External join outcome unknown or inconsistent")
                    }
                    if receipt.state == "rejected", receipt.rejection_reason == "head_conflict", receipt.rejected_at != nil {
                        guard self?.mlsClient.removePendingGenerationJoin(cid: cid.rawValue, expected: frozen) == true else { throw ClientError("External join rejection owner changed") }
                        try self?.durableInboxStore.discardLocalJoinReceipt(accountId: account, scopeCid: cid.rawValue)
                        throw ClientError.Unexpected("External join head conflict")
                    }
                    guard receipt.state == "accepted", receipt.event_id != nil else {
                        throw ClientError.Unexpected("External join outcome unknown")
                    }
                    log.info("session_join operation_id=\(operation.lowercased()) stage=accepted", subsystems: .mls)
                    completion(.success((candidate: frozen, initialCursor: receipt.initialCursor)))
                } catch { completion(.failure(error)) }
            }
            apiClient.request(endpoint: receiptEndpoint) { [weak self] first in
                do {
                    try current()
                    let receipt = try first.get()
                    if receipt.state != "outcome_unknown" { settle(first); return }
                    log.info("session_join operation_id=\(operation.lowercased()) stage=submit", subsystems: .mls)
                    self?.apiClient.request(endpoint: Endpoint<ChannelPayload>(path: .externalJoin(cid), method: .post,
                        body: encoded, needDeviceId: true)) { [weak self] _ in
                        do { try current(); self?.apiClient.request(endpoint: receiptEndpoint, completion: settle) }
                        catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }

    private func uploadGroupInfo(in cid: ChannelId, groupInfo: Data, epoch: Int, completion: @escaping (Error?) -> Void) {
        let marker = mlsClient.loadGenerationMarker(cid: cid.rawValue)
        let body = UploadGroupInfoRequestBody(groupInfo: groupInfo, epoch: epoch,
            expected: GiPublicationTarget(groupGeneration: marker?.generation ?? 0, groupId: marker?.groupId?.base64EncodedString()))
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
    /// Canonical metadata selects a topic's own group or its shared parent group.
    /// Old rows retain the parent fallback. If metadata can't be resolved (e.g.
    /// its row isn't in the DB yet) the topic cid is returned unchanged — the caller then
    /// fails to load a group and the message is buffered for retry, same as any missing group.
    func mlsGroupCid(for cid: ChannelId) -> ChannelId {
        guard cid.type == .topic else { return cid }
        var resolved = cid
        e2eReadContext.performAndWait {
            guard let dto = ChannelDTO.load(cid: cid, context: e2eReadContext),
                  let parentCid = try? ChannelId(cid: dto.mlsGroupCid) else { return }
            resolved = parentCid
        }
        return resolved
    }

    func groupGeneration(for cid: ChannelId) -> Int {
        let effectiveCid = mlsGroupCid(for: cid)
        return Int(mlsClient.loadGenerationMarker(cid: effectiveCid.rawValue)?.generation ?? 0)
    }

    // Existing coalesced sync wakes the message repository; it owns HTTP and projection.
    var resumeOutgoingReconciliation: (() -> Void)?
    func pendingOutgoingReconciliations() throws -> [MlsSendIntent] {
        try performMlsMutation(cidString: "__send_intent__") {
            try self.mlsClient.sendIntentStore().pendingReconciliations(owner: self.mlsClient.sendIntentOwner())
        }
    }

    private func captureSendOwnerFence() throws -> () throws -> Void {
        guard let identity = mlsClient.identity, let user = mlsClient.userId,
              let device = mlsClient.currentDeviceId else { throw MlsSendIntentError.conflict }
        return { [weak self] in
            guard let self, self.mlsClient.hasSetup, self.mlsClient.identity === identity,
                  self.mlsClient.userId == user, self.mlsClient.currentDeviceId == device else {
                throw MlsSendIntentError.conflict
            }
        }
    }

    func outgoingSendIntent(uuid: String) throws -> MlsSendIntent? {
        guard mlsClient.hasSetup else { return nil }
        return try performMlsMutation(cidString: "__send_intent__") {
            try self.mlsClient.sendIntentStore().load(uuid: uuid.lowercased(), owner: self.mlsClient.sendIntentOwner())
        }
    }

    func prepareOutgoingSend(_ request: MessageRequestBody, payload: E2ePayload, cid: ChannelId) throws -> MlsSendIntent {
        let groupCid = mlsGroupCid(for: cid).rawValue
        return try performMlsMutation(cidString: groupCid) {
            let owner = try self.mlsClient.sendIntentOwner()
            let assertCurrent = try self.captureSendOwnerFence()
            let store = try self.mlsClient.sendIntentStore()
            var record = try store.load(uuid: request.id.lowercased(), owner: owner)
            if let existing = record {
                guard existing.cid == groupCid else { throw MlsSendIntentError.conflict }
                if existing.phase == .failedUnsealed { throw MlsSendIntentError.explicitRetryRequired }
                if existing.phase == .accepted || existing.phase == .canceled { throw MlsSendIntentError.terminal }
                if existing.ciphertext != nil { return existing }
            }
            if let control = try self.installedRecoveryControl(cid: groupCid), control.control.action == .manualInterventionRequired {
                throw ClientError.Unexpected("mls_manual_intervention_required")
            }
            if record == nil {
                let binding = try self.mlsClient.applicationSendBinding(cid: groupCid)
                guard request.groupGeneration == nil || (request.groupGeneration! >= 0 && UInt64(request.groupGeneration!) == binding.0) else { throw MlsSendIntentError.conflict }
                let aad = try request.authenticatedAAD()?.encoded() ?? Data()
                let payloadBytes = try JSONEncoder().encode(payload)
                var immutableRequest = request
                immutableRequest.cid = cid
                let envelope = try JSONEncoder.ermis.encode(["message": immutableRequest])
                let scopeBytes = try JSONEncoder().encode([owner, cid.rawValue, groupCid, String(binding.0), binding.1.base64EncodedString(), binding.2])
                let scope = SHA256.hash(data: scopeBytes).map { String(format: "%02x", $0) }.joined()
                let created = MlsSendIntent(version: 1, uuid: request.id.lowercased(), owner: owner,
                    cid: groupCid, scope: scope, groupId: binding.1, generation: binding.0, providerId: binding.2,
                    payload: payloadBytes, aad: aad, originalEnvelope: envelope, phase: .unsealed,
                    ciphertext: nil, epoch: nil, wireEnvelope: nil, revision: 0)
                record = try store.save(created, replacing: nil) { try assertCurrent() }
            }
            guard let original = record else { throw MlsSendIntentError.invalid }
            do {
                let artifact: ApplicationSendArtifact
                if let legacyCipher = request.encryptedData, let epoch = request.mlsEpoch {
                    // Imported pre-journal ciphertext has already crossed the old dispatch path.
                    // Preserve exact bytes and conservatively reconcile; never reseal it.
                    guard epoch >= 0 else { throw MlsSendIntentError.invalid }
                    artifact = ApplicationSendArtifact(ciphertext: Data(legacyCipher), epoch: UInt64(epoch))
                } else {
                    artifact = try self.mlsClient.prepareApplicationSend(original)
                }
                var sealed = original; sealed.phase = .sealed; sealed.revision += 1
                sealed.ciphertext = artifact.ciphertext; sealed.epoch = artifact.epoch
                sealed.nativeSealed = request.encryptedData == nil
                sealed.wireEnvelope = try Self.applicationSendEnvelope(original, artifact: artifact)
                var selected = try store.save(sealed, replacing: original) { try assertCurrent() }
                if request.encryptedData != nil {
                    var imported = selected; imported.phase = .dispatched; imported.revision += 1
                    selected = try store.save(imported, replacing: selected) { try assertCurrent() }
                }
                return selected
            } catch {
                // Leave the original intent recoverable after a native commit/client-save gap.
                // An explicit Retry resumes this UUID and native artifact; no new encryption.
                var failed = original; failed.phase = .failedUnsealed; failed.revision += 1
                _ = try? store.save(failed, replacing: original, assertCurrent: assertCurrent)
                throw error
            }
        }
    }

    private static func applicationSendEnvelope(_ intent: MlsSendIntent, artifact: ApplicationSendArtifact) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: intent.originalEnvelope) as? [String: Any],
              var message = root["message"] as? [String: Any],
              (message["id"] as? String)?.lowercased() == (intent.editMessageId ?? intent.uuid) else { throw MlsSendIntentError.invalid }
        message["mls_ciphertext"] = artifact.ciphertext.base64EncodedString()
        message["mls_epoch"] = artifact.epoch
        message["group_generation"] = intent.generation
        for key in ["text", "attachments", "sticker_url", "old_texts"] { message.removeValue(forKey: key) }
        root["message"] = message
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func outgoingSessionFence(_ intent: MlsSendIntent) throws -> () throws -> Void {
        try performMlsMutation(cidString: intent.cid) {
            guard try self.mlsClient.sendIntentOwner() == intent.owner else { throw MlsSendIntentError.conflict }
            return try self.captureSendOwnerFence()
        }
    }

    func prepareOutgoingCaptionEdit(_ snapshot: E2eeCaptionEditSnapshot) throws -> MlsSendIntent {
        let destination = try ChannelId(cid: snapshot.cid)
        let groupCid = mlsGroupCid(for: destination).rawValue
        return try performMlsMutation(cidString: groupCid) {
            let owner = try self.mlsClient.sendIntentOwner(), fence = try self.captureSendOwnerFence()
            let store = try self.mlsClient.captionEditIntentStore()
            var record = try store.load(uuid: snapshot.operationId, owner: owner)
            if let existing = record {
                guard existing.editMessageId == snapshot.messageId, existing.cid == groupCid,
                      existing.originalEnvelope == snapshot.originalEnvelope,
                      existing.editBaseCiphertextHash == snapshot.baseCiphertextHash,
                      (try JSONDecoder().decode(E2ePayload.self, from: existing.payload)) == snapshot.payload,
                      existing.aad == snapshot.aad else {
                    throw MlsSendIntentError.conflict
                }
                if existing.ciphertext != nil { return existing }
                if existing.phase == .failedUnsealed {
                    var retry = existing; retry.phase = .unsealed; retry.revision += 1
                    record = try store.save(retry, replacing: existing, assertCurrent: fence)
                }
            }
            if record == nil {
                if let control = try self.installedRecoveryControl(cid: groupCid), control.control.action == .manualInterventionRequired {
                    throw ClientError.Unexpected("mls_manual_intervention_required")
                }
                let binding = try self.mlsClient.applicationSendBinding(cid: groupCid)
                _ = try E2eeArchiveMessageValidator.validate(snapshot.payload, processedAAD: snapshot.aad,
                    messageId: snapshot.messageId, cid: snapshot.cid, groupCid: groupCid)
                let scopeBytes = try JSONEncoder().encode([owner, snapshot.cid, groupCid, String(binding.0), binding.1.base64EncodedString(), binding.2])
                let scope = SHA256.hash(data: scopeBytes).map { String(format: "%02x", $0) }.joined()
                var created = MlsSendIntent(version: 1, uuid: snapshot.operationId, owner: owner,
                    cid: groupCid, scope: scope, groupId: binding.1, generation: binding.0, providerId: binding.2,
                    payload: try JSONEncoder().encode(snapshot.payload), aad: snapshot.aad,
                    originalEnvelope: snapshot.originalEnvelope, phase: .unsealed, ciphertext: nil,
                    epoch: nil, wireEnvelope: nil, revision: 0)
                created.editMessageId = snapshot.messageId; created.editBaseCiphertextHash = snapshot.baseCiphertextHash
                record = try store.save(created, replacing: nil, assertCurrent: fence)
            }
            guard let original = record else { throw MlsSendIntentError.invalid }
            do {
                let artifact = try self.mlsClient.prepareApplicationSend(original)
                var next = original; next.phase = .sealed; next.revision += 1
                next.ciphertext = artifact.ciphertext; next.epoch = artifact.epoch; next.nativeSealed = true
                next.wireEnvelope = try Self.applicationSendEnvelope(original, artifact: artifact)
                return try store.save(next, replacing: original, assertCurrent: fence)
            } catch {
                var failed = original; failed.phase = .failedUnsealed; failed.revision += 1
                _ = try? store.save(failed, replacing: original, assertCurrent: fence)
                throw error
            }
        }
    }

    func validateOutgoingAcceptance(_ intent: MlsSendIntent, message: MessagePayload, destination: ChannelId) throws {
        try performMlsMutation(cidString: intent.cid) {
            guard try self.mlsClient.sendIntentOwner() == intent.owner,
                  message.user.id == self.mlsClient.userId,
                  message.sendingDeviceId == self.mlsClient.currentDeviceId,
                  message.id.lowercased() == (intent.editMessageId ?? intent.uuid),
                  message.encryptedData.map({ Data($0) }) == intent.ciphertext,
                  message.mlsEpoch.map({ $0 >= 0 ? UInt64($0) : UInt64.max }) == intent.epoch,
                  message.groupGeneration >= 0, UInt64(message.groupGeneration) == intent.generation,
                  message.canonicalMessageSequence.map({ $0 > 0 }) == true,
                  message.cid == nil || message.cid == destination else { throw MlsSendIntentError.conflict }
            let root = try JSONSerialization.jsonObject(with: intent.wireEnvelope ?? Data()) as? [String: Any]
            guard let envelope = root?["message"] as? [String: Any],
                  (envelope["parent_id"] as? String) == message.parentId,
                  (envelope["quoted_message_id"] as? String) == message.quotedMessageId,
                  (envelope["forward_cid"] as? String) == message.forwardChannelId?.rawValue,
                  (envelope["forward_message_id"] as? String) == message.forwardMessageId,
                  (envelope["mentioned_all"] as? Bool ?? false) == message.mentionedAll,
                  Set(envelope["mentioned_users"] as? [String] ?? []) == Set(message.mentionedUsers),
                  Set(envelope["e2ee_attachment_ids"] as? [String] ?? []) == Set(message.e2eeAttachmentIds) else {
                throw MlsSendIntentError.conflict
            }
            if let parent = envelope["forward_parent_cid"] as? String {
                guard parent == message.forwardParentCid else { throw MlsSendIntentError.conflict }
            }
        }
    }

    func assertOutgoingOwner(_ intent: MlsSendIntent) throws {
        try performMlsMutation(cidString: intent.cid) {
            guard try self.mlsClient.sendIntentOwner() == intent.owner,
                  let current = try self.mlsClient.outgoingIntentStore(intent).load(uuid: intent.uuid, owner: intent.owner),
                  current.requiresReconcile, current.ciphertext == intent.ciphertext,
                  current.wireEnvelope == intent.wireEnvelope else { throw MlsSendIntentError.conflict }
        }
    }

    func markOutgoingDispatch(_ original: MlsSendIntent) throws -> MlsSendIntent {
        try performMlsMutation(cidString: original.cid) {
            guard try self.mlsClient.sendIntentOwner() == original.owner else { throw MlsSendIntentError.conflict }
            let assertCurrent = try self.captureSendOwnerFence()
            if original.requiresReconcile { return original }
            guard original.phase == .sealed else { throw MlsSendIntentError.terminal }
            var next = original; next.phase = .dispatched; next.revision += 1
            return try self.mlsClient.outgoingIntentStore(original).save(next, replacing: original) {
                try assertCurrent()
            }
        }
    }

    func retryOutgoingSend(uuid: String) throws {
        try performMlsMutation(cidString: "__send_intent__") {
            let owner = try self.mlsClient.sendIntentOwner(), store = try self.mlsClient.sendIntentStore()
            let assertCurrent = try self.captureSendOwnerFence()
            guard let original = try store.load(uuid: uuid.lowercased(), owner: owner) else { return }
            guard original.phase != .accepted, original.phase != .canceled,
                  original.phase != .canceledDispatched else { throw MlsSendIntentError.terminal }
            if original.phase == .failedUnsealed {
                var retry = original; retry.phase = .unsealed; retry.revision += 1
                try store.save(retry, replacing: original) { try assertCurrent() }
            }
        }
    }

    func cancelOutgoingSend(uuid: String, destination: ChannelId) throws -> MlsSendIntent? {
        try performMlsMutation(cidString: "__send_intent__") {
            let owner = try self.mlsClient.sendIntentOwner(), fence = try self.captureSendOwnerFence()
            let store = try self.mlsClient.sendIntentStore()
            guard let original = try store.load(uuid: uuid.lowercased(), owner: owner) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: original.originalEnvelope) as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  (message["cid"] as? String).map({ $0 == destination.rawValue }) ?? true else { throw MlsSendIntentError.conflict }
            if original.phase == .accepted { return nil }
            if original.phase == .canceled || original.phase == .canceledDispatched { return original }
            var canceled = original
            // A client-unsealed record can already own a committed native ciphertext after
            // process death. Recover exact bytes, persist their retirement hash authority with
            // cancellation, then retire. Never infer native absence from a client phase flag.
            if original.ciphertext == nil, let recovered = try self.mlsClient.recoverApplicationSend(original) {
                canceled.ciphertext = recovered.ciphertext
                canceled.epoch = recovered.epoch
                canceled.wireEnvelope = try Self.applicationSendEnvelope(original, artifact: recovered)
                canceled.nativeSealed = true
            }
            canceled.phase = original.requiresReconcile ? .canceledDispatched : .canceled
            canceled.revision += 1
            try store.save(canceled, replacing: original, assertCurrent: fence)
            if canceled.phase == .canceled { try self.finishOutgoingRetirement(canceled, store: store, assertCurrent: fence) }
            return canceled
        }
    }

    func acceptOutgoingSend(_ original: MlsSendIntent) throws {
        try performMlsMutation(cidString: original.cid) {
            guard try self.mlsClient.sendIntentOwner() == original.owner else { throw MlsSendIntentError.conflict }
            let assertCurrent = try self.captureSendOwnerFence()
            let store = try self.mlsClient.outgoingIntentStore(original)
            guard let current = try store.load(uuid: original.uuid, owner: original.owner),
                  current.ciphertext == original.ciphertext, current.wireEnvelope == original.wireEnvelope else { throw MlsSendIntentError.conflict }
            if current.phase == .accepted && current.nativeRetired { return }
            var accepted = current
            if accepted.phase != .accepted {
                accepted.phase = .accepted; accepted.revision += 1
                try store.save(accepted, replacing: current, assertCurrent: assertCurrent)
            }
            try self.finishOutgoingRetirement(accepted, store: store, assertCurrent: assertCurrent)
        }
    }

    private func finishOutgoingRetirement(_ terminal: MlsSendIntent, store: MlsSendIntentStore,
                                           assertCurrent: () throws -> Void) throws {
        guard [.accepted, .canceled].contains(terminal.phase) else { throw MlsSendIntentError.terminal }
        if terminal.nativeRetired { return }
        try assertCurrent()
        if terminal.nativeSealed { try mlsClient.retireApplicationSend(terminal) }
        var retired = terminal; retired.nativeRetired = true; retired.revision += 1
        try store.save(retired, replacing: terminal, assertCurrent: assertCurrent)
    }

    private func resumeOutgoingRetirements() {
        do {
            try performMlsMutation(cidString: "__send_retirement__") {
                let owner = try self.mlsClient.sendIntentOwner(), fence = try self.captureSendOwnerFence()
                let store = try self.mlsClient.sendIntentStore()
                for record in try store.pendingRetirements(owner: owner) {
                    do { try self.finishOutgoingRetirement(record, store: store, assertCurrent: fence) }
                    catch { log.warning("mls_send_retirement result=retained_for_next_wake", subsystems: .mls) }
                }
            }
        } catch { log.warning("mls_send_retirement result=owner_or_storage_unavailable", subsystems: .mls) }
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
        guard mlsClient.loadPendingGenerationJoin(cid: groupCid)?.candidateFenceVersion != 1 else { throw ClientError("External join outcome pending") }
        let scopedTrace = trace?.scoped(to: groupCid)
        guard message.attachments.isEmpty else { throw E2eeMessageAADError.authenticatedMetadataMismatch }
        if !message.e2eeAttachments.isEmpty {
            guard let authenticatedAAD else { throw E2eeMessageAADError.authenticatedMetadataMismatch }
            let metadata = try E2eeMessageAADV1.decoded(from: authenticatedAAD)
            guard metadata.cid == cid.rawValue, metadata.e2eeGroupId == groupCid else { throw E2eeMessageAADError.authenticatedMetadataMismatch }
            try message.e2eeAttachments.verifyCanonicalAttachmentIds(metadata.attachmentIds)
        }
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
                if let control = try self.installedRecoveryControl(cid: groupCid),
                   control.control.action == .manualInterventionRequired {
                    throw ClientError.Unexpected("mls_manual_intervention_required")
                }
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
        historyPageLock.lock(); historyPageSession = UUID(); sessionProgress.invalidate(); lastRequestedHistoryPage = nil; historyPagesInFlight.removeAll(); channelListPreviews.removeAll(); historyPageLock.unlock()
        do { try archiveRecovery?.stop() } catch { log.error("archive_recovery stage=logout_clear_failed", subsystems: .mls) }
        archiveRecovery = nil
        abortSync()
        syncLock.lock(); unverifiedLiveSyncScopes.removeAll(); successfulSyncScopes.removeAll(); pendingSyncReadinessScopes.removeAll()
        liveSyncCoverage.removeAll(); scopeSyncDemand.removeAll(); successfulSyncDemand.removeAll(); activeSyncMembershipDates.removeAll(); syncLock.unlock()
        bootstrapQueue.reset()
        syncThrottleQueue.async { [weak self] in
            self?.pendingSyncWorkItem?.cancel(); self?.pendingSyncWorkItem = nil; self?.lastSyncTriggeredAt = nil
        }
        readinessLock.lock()
        readinessByCid.removeAll()
        dormantBootstrapScopes.removeAll()
        bootstrapStartedAt.removeAll()
        lastBootstrapConnectionId = nil
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
        // A latest-message preview or realtime event can arrive ahead of older ciphertexts.
        // Consuming its ratchet key here discards skipped keys before ordered scope replay.
        // Display callers may read bound cache; only the durable scope owner consumes MLS.
        let groupCid = mlsGroupCid(for: cid).rawValue
        let assertOwner = captureRetainedHistoryOwner()
        let publishCached: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try assertOwner()
                if try self.boundDisplayPayload(messageId: messageId, encryptedData: encryptedData,
                                               expectedEnvelope: expectedEnvelope) == nil,
                   let accountId = self.mlsClient.userId,
                   let retained = try self.durableInboxStore.skippedCaptionUpdate(accountId: accountId,
                       scopeCid: groupCid, messageId: messageId, ciphertext: encryptedData),
                   case .messageUpdated(let update) = retained.event,
                   update.message.groupGeneration == self.groupGeneration(for: cid) {
                    try assertOwner()
                    try self.reDecryptUpdatedMessageSync(messageId: messageId, encryptedData: encryptedData,
                        cid: cid, receiveSource: .scopeSync, expectedEnvelope: update.message.e2eeReceivedEnvelope)
                    try assertOwner()
                    try self.durableInboxStore.markSkippedCaptionUpdateRepaired(accountId: accountId,
                        scopeCid: groupCid, envelope: retained)
                }
                guard let payload = try self.boundDisplayPayload(
                    messageId: messageId, encryptedData: encryptedData, expectedEnvelope: expectedEnvelope
                ) else {
                    completion?(.failure(ClientError.Unexpected("Message is waiting for encrypted history sync.")))
                    return
                }
                self.e2eeAttachmentReceiveCoordinator.hydratePreviews(
                    payload: payload, messageId: messageId, cid: cid, source: receiveSource
                )
                completion?(.success(payload))
            } catch {
                completion?(.failure(error))
            }
        }
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            do {
                try assertOwner()
                if try self.boundDisplayPayload(messageId: messageId, encryptedData: encryptedData,
                                               expectedEnvelope: expectedEnvelope) != nil {
                    publishCached()
                    return
                }
            } catch {
                completion?(.failure(error))
                return
            }
            var historicalGeneration: Int?
            let currentGeneration = self.groupGeneration(for: cid)
            self.e2eReadContext.performAndWait {
                if let row = self.e2eReadContext.message(id: messageId), row.encryptedData == encryptedData,
                   row.mlsGroupGeneration < currentGeneration {
                    historicalGeneration = Int(row.mlsGroupGeneration)
                }
            }
            if let generation = historicalGeneration {
                do { completion?(.success(try self.retainedHistoricalPayload(messageId: messageId,
                    encryptedData: encryptedData, cid: cid, generation: generation, expectedEnvelope: expectedEnvelope))) }
                catch { completion?(.failure(error)) }
                return
            }
            // A commit's pending-message sweep is already inside scope catch-up. Its ordered
            // application events will publish the cache; do not recursively start another scan.
            guard receiveSource != .scopeSync else { publishCached(); return }
            self.runSync(forCidStrings: [groupCid]) { [weak self] in
                self?.enqueueGroupOperation(BlockOperation(block: publishCached), cidString: groupCid)
            }
        }
        op.queuePriority = .high
        enqueueGroupOperation(op, cidString: groupCid)
    }

    private func captureRetainedHistoryOwner() -> () throws -> Void {
        let user = mlsClient.userId, device = mlsClient.currentDeviceId
        let provider = mlsClient.provider, identity = mlsClient.identity
        return { [weak self] in
            guard let self, user != nil, self.mlsClient.userId == user,
                  self.mlsClient.currentDeviceId == device, self.mlsClient.provider === provider,
                  self.mlsClient.identity === identity else { throw ClientError.Unexpected("Historical MLS owner changed.") }
        }
    }

    /// Local read of a retained generation; caller is on the existing mutation executor.
    private func retainedHistoricalPayload(messageId: MessageId, encryptedData: Data, cid: ChannelId,
        generation: Int, expectedEnvelope: E2eeReceivedMessageEnvelope? = nil) throws -> E2ePayload {
        let assertOwner = captureRetainedHistoryOwner(); try assertOwner()
        if let cached = try boundDisplayPayload(messageId: messageId, encryptedData: encryptedData, expectedEnvelope: expectedEnvelope) { try assertOwner(); return cached }
        guard generation >= 0 else { throw ClientError.Unexpected("Invalid historical MLS generation.") }
        let processed = try mlsClient.processRetainedHistoricalApplication(data: encryptedData,
            cid: mlsGroupCid(for: cid).rawValue, generation: UInt64(generation))
        let payload = try validatedPayload(processed.payload, processedAAD: processed.aad,
            messageId: messageId, cid: cid, expectedEnvelope: expectedEnvelope)
        let hash = Data(SHA256.hash(data: encryptedData)); try assertOwner()
        try database.writeAndWait { session in
            try assertOwner()
            try session.saveMessageDecrypt(payload: payload, messageId: messageId, ciphertextHash: hash)
            session.message(id: messageId)?.text = payload.text
        }
        e2eeAttachmentReceiveCoordinator.hydratePreviews(payload: payload, messageId: messageId, cid: cid, source: .directDecrypt)
        return payload
    }

    private func boundDisplayPayload(
        messageId: MessageId,
        encryptedData: Data,
        expectedEnvelope: E2eeReceivedMessageEnvelope?
    ) throws -> E2ePayload? {
        var payload: E2ePayload?
        let hash = Data(SHA256.hash(data: encryptedData))
        let context = e2eReadContext
        context.performAndWait {
            guard let row = MessageDecryptDTO.load(messageId: messageId, context: context),
                  row.ciphertextHash == hash else { return }
            payload = try? row.asPayload()
        }
        if let payload { try validateCachedPayload(payload, expectedEnvelope: expectedEnvelope) }
        return payload
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
        let messageGeneration = message.mlsGroupGeneration ?? 0
        guard messageGeneration <= currentGeneration, messageGeneration >= 0 else {
            completion(.failure(ClientError.Unexpected("Message belongs to a future MLS group generation.")))
            return
        }
        if messageGeneration < currentGeneration {
            let owner = mlsClient.userId, provider = mlsClient.provider, identity = mlsClient.identity, device = mlsClient.currentDeviceId
            let op = BlockOperation { [weak self] in
                guard let self, self.mlsClient.userId == owner, self.mlsClient.provider === provider, self.mlsClient.identity === identity, self.mlsClient.currentDeviceId == device else { completion(.failure(ClientError.Unexpected("Historical MLS owner changed."))); return }
                do {
                    let payload: E2ePayload
                    if let cached = try self.boundDisplayPayload(messageId: message.id, encryptedData: encryptedData, expectedEnvelope: nil) {
                        payload = cached
                    } else {
                        let processed = try self.mlsClient.processRetainedHistoricalApplication(data: encryptedData,
                            cid: self.mlsGroupCid(for: cid).rawValue, generation: UInt64(messageGeneration))
                        payload = try self.validatedPayload(processed.payload, processedAAD: processed.aad,
                            messageId: message.id, cid: cid, expectedEnvelope: nil)
                        let hash = Data(SHA256.hash(data: encryptedData))
                        try self.database.writeAndWait { session in
                            guard self.mlsClient.userId == owner, self.mlsClient.provider === provider, self.mlsClient.identity === identity, self.mlsClient.currentDeviceId == device else { throw ClientError.Unexpected("Historical MLS owner changed.") }
                            try session.saveMessageDecrypt(payload: payload, messageId: message.id, ciphertextHash: hash)
                            session.message(id: message.id)?.text = payload.text
                        }
                    }
                    var updated = message; updated.text = payload.text; updated.stickerUrl = payload.stickerUrl; updated.decryptedMessage = payload
                    self.e2eeAttachmentReceiveCoordinator.hydratePreviews(payload: payload, messageId: message.id, cid: cid, source: .directDecrypt)
                    completion(.success(updated))
                } catch { completion(.failure(error)) }
            }
            op.queuePriority = .high
            enqueueGroupOperation(op, cidString: mlsGroupCid(for: cid).rawValue)
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
