import Foundation
import CryptoKit
import open_mls_ios

public struct E2eeArchiveRecoveryStatus: Sendable {
    public let hasVault: Bool
    public let unlocked: Bool
    public let state: String
    public let cid: String?
    public let restoredMessages: Int
    public let reason: String?
    public let requiresPinChannels: Set<String>
    public var pinRequestRevision: UInt64 = 0
    public var historyState: String? = nil
    public var historyReason: String? = nil
    public var historySummary: String? {
        let history = historyState ?? state; let gap = historyReason ?? reason
        if history == "permission_denied" { return "Bạn không có quyền khôi phục lịch sử này." }
        if gap == "material_unavailable" || gap == "no_usable_archive" { return "Một số tin nhắn chưa có dữ liệu khôi phục." }
        if gap == "aad" || gap == "payload_schema" { return "Một số tin nhắn không đủ thông tin xác thực." }
        if history == "coverage_unknown" { return "Đã khôi phục các tin đủ điều kiện; chưa xác minh được toàn bộ lịch sử." }
        if history == "done_with_gaps" { return "Một số tin nhắn chưa khôi phục được." }
        if history == "retryable_error" || history == "queued" { return "Khôi phục sẽ tiếp tục khi kết nối hoặc bộ nhớ khả dụng." }
        if history == "terminal" { return "Khôi phục chưa hoàn tất cho phạm vi này." }
        return nil
    }
}

public struct E2eeArchiveRecord: Sendable {
    public let cid: String
    public let epoch: UInt64
    public let scope: String
    public let savedAt: Date
}

public extension Notification.Name {
    static let ermisArchiveRecoveryStateChanged = Notification.Name("io.ermis.archive.recovery.state")
    static let ermisArchiveLoginPinRequested = Notification.Name("io.ermis.archive.login.pin")
}

private struct ArchiveCheckpoint: Codable {
    let archive: Data
    let snapshot: Data
    let hash: String
    var blobId: String
    let sponsorRole: String
    var rewraps: Int
    var ownLeafIndex: UInt32? = nil
    var primaryUser: String? = nil
}
private struct ArchiveCachedKey: Codable { let keyId: String; let privateKey: Data }
private struct ArchiveRestoreJob: Codable { let from: UInt64?; let to: UInt64?; var cycle: String? = nil; var validatorVersion: Int? = 2; var coverage: String? = nil; var coverageVersion: Int? = nil; var requestId: String? = nil }
private struct ArchiveRestoreProgress: Codable {
    let cursor: E2eeArchiveWire?; let restored: Int; let hasGaps: Bool; var cycle: String? = nil
    var validatorVersion: Int? = 2; var discovered: Int? = 0; var safeSkipped: Int? = 0
    var reasons: [String: Int]? = [:]; var outcomes: [String: String]? = [:]
    var cryptoSuccess: Int? = 0
    var coverage: String? = nil; var coverageVersion: Int? = nil
}
private struct ArchiveCensus: Codable {
    let from: UInt64; let to: UInt64; let cycle: String
    var cursor: E2eeArchiveWire? = nil; var ids: [UInt64: [String]] = [:]
    var pages = 0; var bytes = 0; var state = "discovering"; var reason: String? = nil; var version = 2
}

/// Recovery and upload serialize independently from live MLS mutation. Shared Rust journal owns durability.
public actor E2eeArchiveRecovery {
    nonisolated private let journal: RecoveryJournal
    nonisolated private let keys: E2eeRecoveryKeyStore
    nonisolated private let session = E2eeArchiveSession()
    private let userId: String
    private let api: APIClient?
    private let requestOverride: ((Endpoint<E2eeArchiveWire>) async throws -> E2eeArchiveWire)?
    private let isCurrentAccount: () -> Bool
    private let generation: (String) throws -> UInt64
    private let apply: (String, UInt64, Data, Data, E2eeArchiveWire) throws -> Void
    private var vault: E2eeArchiveWire?
    private var tail: Task<Void, Never>?
    private var drainQueued = false
    private var retryTask: Task<Void, Never>?
    private var pendingPinChannels = Set<String>()
    private var latest = E2eeArchiveRecoveryStatus(hasVault: false, unlocked: false, state: "idle", cid: nil,
        restoredMessages: 0, reason: nil, requiresPinChannels: [])

    init(namespace: String, root: URL, userId: String, api: APIClient?, isCurrentAccount: @escaping () -> Bool,
         generation: @escaping (String) throws -> UInt64,
         apply: @escaping (String, UInt64, Data, Data, E2eeArchiveWire) throws -> Void,
         requestOverride: ((Endpoint<E2eeArchiveWire>) async throws -> E2eeArchiveWire)? = nil) throws {
        self.userId = userId; self.api = api; self.requestOverride = requestOverride; self.isCurrentAccount = isCurrentAccount
        self.generation = generation; self.apply = apply
        keys = E2eeRecoveryKeyStore(namespace: namespace)
        let directory = root.appendingPathComponent("MLSArchive/\(namespace)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try url.setResourceValues(resources)
        journal = try RecoveryJournal(path: directory.appendingPathComponent("journal.db").path)
        if let saved = try journal.get(key: "vault") { vault = try JSONDecoder().decode(E2eeArchiveWire.self, from: saved.payload) }
        pendingPinChannels = Set(try journal.page(kind: "restore", status: "requires_pin", now: .max, cid: nil, afterKey: nil, limit: 50).map(\.cid))
    }

    nonisolated public func clearRecoveryUnlock() throws { try session.write { try keys.clearUnlock() } }
    nonisolated func stop(clearUnlock: Bool = true) throws { try session.stop { if clearUnlock { try keys.clearUnlock() } }; Task { await cancelRuntime() } }
    private func cancelRuntime() { retryTask?.cancel(); tail?.cancel(); pendingPinChannels.removeAll() }
    private func active() throws {
        try session.check()
        guard isCurrentAccount() else {
            try? session.stop {}; retryTask?.cancel()
            throw E2eeArchiveError.sessionEnded
        }
    }
    private func activeRestore(_ cid: String, _ gen: UInt64) throws {
        try active(); guard try generation(cid) == gen else { throw E2eeArchiveError.generationChanged }
    }
    private func serialized<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { await previous?.value; try active(); return try await work() }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
    private func request(_ endpoint: Endpoint<E2eeArchiveWire>) async throws -> E2eeArchiveWire {
        try active()
        let response: E2eeArchiveWire
        let started=DispatchTime.now().uptimeNanoseconds
        do {
            if let requestOverride { response = try await requestOverride(endpoint) }
            else if let api { response = try await api.request(endpoint: endpoint) }
            else { throw E2eeArchiveError.sessionEnded }
        } catch { E2eeArchiveCost.record("http","error",started);throw error }
        #if DEBUG
        E2eeArchiveCost.record("http","success",started,bytes:(try? JSONEncoder().encode(response).count) ?? 0)
        #endif
        try active()
        return response
    }
    private func loadVault() async throws {
        do {
            let response = try await request(.recoveryVault())
            guard let bytes = response["vault_bytes"].bytes, let keyId = response["recovery_key_id"].string else { throw E2eeArchiveError.invalidData }
            let metadata = try recoveryVaultMetadata(vault: bytes)
            guard metadata.keyId == keyId else { throw E2eeArchiveError.invalidData }
            try session.write { try journal.put(entry: row("vault", kind: "metadata", payload: response, status: "ready")); vault = response }
        } catch {
            guard let apiError = Self.apiError(error), apiError.httpStatusCode == 404 || apiError.message.lowercased().contains("recovery vault not found") else { throw error }
            try session.write { try journal.remove(key: "vault"); vault = nil }
        }
        publish("ready")
    }
    private func cachedKey() throws -> Data? {
        guard let keyId = vault?["recovery_key_id"].string, let data = try keys.loadUnlock() else { return nil }
        guard let cache = try? JSONDecoder().decode(ArchiveCachedKey.self, from: data), cache.privateKey.count == 32 else { return nil }
        return cache.keyId == keyId ? cache.privateKey : nil
    }
    private func publish(_ state: String, cid: String? = nil, reason: String? = nil, restored: Int = 0) {
        guard (try? session.check()) != nil else { return }
        latest = .init(hasVault: vault != nil, unlocked: (try? cachedKey()) != nil, state: state,
            cid: cid, restoredMessages: restored, reason: reason, requiresPinChannels: pendingPinChannels, pinRequestRevision: latest.pinRequestRevision,
            historyState: latest.historyState, historyReason: latest.historyReason)
        NotificationCenter.default.post(name: .ermisArchiveRecoveryStateChanged, object: self, userInfo: ["status": latest])
        log.info("archive_recovery stage=\(state) reason=\(reason ?? "none") restored=\(restored)", subsystems: .mls)
    }
    public func getRecoveryStatus() async throws -> E2eeArchiveRecoveryStatus {
        try await serialized { try await self.loadVault(); return try await self.durableStatus() }
    }
    private func durableStatus() throws -> E2eeArchiveRecoveryStatus {
        var states=Set<String>()
        for state in ["done","done_with_gaps","coverage_unknown","permission_denied","queued","terminal"] {
            var after:String?;var count=0
            repeat {
                let rows=try journal.page(kind:"restore",status:state,now:.max,cid:nil,afterKey:after,limit:50)
                guard let last=rows.last else {break}
                after=Self.cursor(last);count += rows.count
                for row in rows {
                    guard let current=try? generation(row.cid) else {states.insert("coverage_unknown");continue}
                    guard row.groupGeneration==current else {continue}
                    let job=try JSONDecoder().decode(ArchiveRestoreJob.self,from:row.payload)
                    states.insert(state=="done" && (job.coverage != "covered" || job.coverageVersion != 2) ? "coverage_unknown" : state)
                }
            } while count<1000
            if count>=1000 {states.insert("coverage_unknown")}
        }
        let history=["coverage_unknown","queued","done_with_gaps","permission_denied","terminal","done"].first {states.contains($0)}
        latest.historyState=history;latest.historyReason=history
        return latest
    }
    public func currentStatus() -> E2eeArchiveRecoveryStatus { latest }
    public func setupRecoveryPin(_ pin: String) async throws {
        try await serialized { try await self.setup(pin) }
        resume(); resumeRestores()
    }

    /// Rewraps the same recovery private key with a new PIN; archive key identity stays stable.
    public func rotateRecoveryPin(currentPin: String, newPin: String) async throws {
        try await serialized { try await self.rotatePin(currentPin: currentPin, newPin: newPin) }
        resume(); resumeRestores()
    }

    public func uploadedArchives(limit: Int = 200) throws -> [E2eeArchiveRecord] {
        let boundedLimit = max(1, min(limit, 1000))
        var records: [E2eeArchiveRecord] = []
        for status in ["uploaded", "idempotent"] {
            var after: String?
            while records.count < boundedLimit {
                let page = try journal.page(kind: "ack", status: status, now: .max, cid: nil, afterKey: after, limit: 100)
                guard let last = page.last else { break }
                records.append(contentsOf: page.map { E2eeArchiveRecord(cid: $0.cid, epoch: $0.epoch, scope: $0.scope, savedAt: Date(timeIntervalSince1970: TimeInterval($0.createdAt) / 1000)) })
                after = Self.cursor(last)
            }
        }
        return Array(records.sorted { $0.savedAt > $1.savedAt }.prefix(boundedLimit))
    }

    private func rotatePin(currentPin: String, newPin: String) async throws {
        try await loadVault()
        guard let vault, let bytes = vault["vault_bytes"].bytes,
              let revision = vault["revision"].number else { throw E2eeArchiveError.invalidData }
        let metadata = try open_mls_ios.recoveryVaultMetadata(vault: bytes)
        var privateKey = try open_mls_ios.unlockRecoveryVault(pin: currentPin, vault: bytes)
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }
        let recoveryKeys = RecoveryKeys(privateKey: privateKey, publicKey: metadata.publicKey,
                                        keyId: metadata.keyId, ciphersuite: metadata.ciphersuite)
        let newVaultBytes = try createRecoveryVault(pin: newPin, keys: recoveryKeys)
        let result = try await request(.recoveryVault(body: .object([
            "vault_bytes": .bytes(newVaultBytes), "expected_revision": .uint(revision)
        ])))
        guard result["status"].string == "updated", let newRevision = result["revision"].number else {
            throw E2eeArchiveError.vaultConflict
        }
        let next = E2eeArchiveWire.object(["vault_bytes": .bytes(newVaultBytes), "revision": .uint(newRevision),
                                           "recovery_key_id": .string(metadata.keyId)])
        try session.write {
            try journal.put(entry: row("vault", kind: "metadata", payload: next, status: "ready")); self.vault = next
            try keys.saveUnlock(JSONEncoder().encode(ArchiveCachedKey(keyId: metadata.keyId, privateKey: privateKey)))
        }
        publish("ready")
    }
    private func setup(_ pin: String) async throws {
        try await loadVault()
        guard vault == nil else { throw E2eeArchiveError.vaultConflict }
        var pair = try generateRecoveryKeys()
        defer { pair.privateKey.resetBytes(in: 0..<pair.privateKey.count) }
        let data = try createRecoveryVault(pin: pin, keys: pair)
        let result = try await request(.recoveryVault(body: .object(["vault_bytes": .bytes(data)])))
        guard result["status"].string == "created", let revision = result["revision"].number else { throw E2eeArchiveError.vaultConflict }
        let next = E2eeArchiveWire.object(["vault_bytes": .bytes(data), "revision": .uint(revision), "recovery_key_id": .string(pair.keyId)])
        try session.write {
            try journal.put(entry: row("vault", kind: "metadata", payload: next, status: "ready")); vault = next
            try keys.saveUnlock(JSONEncoder().encode(ArchiveCachedKey(keyId: pair.keyId, privateKey: pair.privateKey)))
        }
        publish("ready")
    }
    public func unlockRecoveryVault(_ pin: String) async throws {
        try await serialized { try await self.unlock(pin) }
        resume(); resumeRestores()
    }
    private func unlock(_ pin: String) async throws {
        try await loadVault()
        guard let vault, let bytes = vault["vault_bytes"].bytes, let keyId = vault["recovery_key_id"].string else { throw E2eeArchiveError.invalidData }
        var privateKey = try open_mls_ios.unlockRecoveryVault(pin: pin, vault: bytes)
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }
        try session.write { try keys.saveUnlock(JSONEncoder().encode(ArchiveCachedKey(keyId: keyId, privateKey: privateKey))) }
        publish("ready")
    }

    /// Called synchronously by the MLS executor; only export once for each captured epoch.
    nonisolated func capture(cid: String, generation: UInt64, group: Group, role: String) throws {
        try session.check()
        let identity = "\(cid):\(generation):\(group.epoch())"
        if try journal.get(key: "captured:\(identity)") != nil { return }
        let exported = try group.archiveEpochV2()
        var archive = exported.archiveBytes
        defer { archive.resetBytes(in: 0..<archive.count) }
        let protected = try keys.protect(archive, purpose: "archive:\(identity)")
        try session.write {
            for scope in ["account_owned", "group_sponsored"] {
                let checkpoint = ArchiveCheckpoint(archive: protected, snapshot: exported.snapshotBytes,
                    hash: Self.hex(exported.snapshotHash), blobId: UUID().uuidString.lowercased(), sponsorRole: role, rewraps: 0, ownLeafIndex: group.ownLeafIndex())
                _ = try journal.insertIfAbsent(entry: Self.entry("checkpoint:\(identity):\(scope)", kind: "checkpoint",
                    cid: cid, generation: generation, epoch: group.epoch(), scope: scope, payload: try JSONEncoder().encode(checkpoint)))
            }
            try journal.put(entry: Self.entry("captured:\(identity)", kind: "captured", cid: cid, generation: generation,
                epoch: group.epoch(), payload: Data(), status: "done"))
        }
        log.info("archive_upload stage=captured epoch=\(group.epoch()) generation=\(generation)", subsystems: .mls)
        Task { await resume() }
    }

    public func resume() {
        guard (try? session.check()) != nil, !drainQueued else { return }
        drainQueued = true
        Task {
            do { try await serialized { await self.drain() } } catch { }
            self.drainQueued = false
            self.scheduleRetry()
        }
    }
    private func drain() async {
        do {
            do { try await loadVault() } catch { publish("retryable_error", reason: "vault_metadata_unavailable") }
            for kind in ["checkpoint", "upload", "restore"] {
                var after: String?
                while true {
                    let items = try journal.page(kind: kind, status: "queued", now: Self.now(), cid: nil, afterKey: after, limit: 50)
                    guard !items.isEmpty else { break }
                    after = Self.cursor(items.last!)
                    for item in items {
                        try active()
                        if kind == "checkpoint" { try await materialize(item) }
                        else if kind == "upload" { try await upload(item) }
                        else {
                            if item.groupGeneration != (try generation(item.cid)) {
                                var old = item; old.status = "superseded"; try session.write { try journal.put(entry: old) }; continue
                            }
                            let job = try JSONDecoder().decode(ArchiveRestoreJob.self, from: item.payload)
                            await restore(item.cid, from: job.from, to: job.to, manual: false, requestedCycle: job.cycle)
                        }
                    }
                }
            }
        } catch { publish("retryable_error", reason: "network_storage_or_device_key_unavailable") }
    }
    private func scheduleRetry() {
        retryTask?.cancel()
        guard (try? session.check()) != nil else { return }
        let rows = ["checkpoint", "upload", "restore"].compactMap { try? journal.page(kind: $0, status: "queued", now: .max, cid: nil, afterKey: nil, limit: 1).first }
        guard let next = rows.map(\.nextRetryAt).min() else { return }
        let delay = UInt64(max(1_000, next - Self.now())) * 1_000_000
        retryTask = Task { try? await Task.sleep(nanoseconds: delay); if !Task.isCancelled { resume() } }
    }
    private func retry(_ item: RecoveryJournalEntry, reason: String) throws {
        var updated = item; updated.retryCount += 1
        let backoff = min(Int64(1_000) << min(Int(updated.retryCount), 9), 300_000)
        updated.nextRetryAt = Self.now() + backoff + Int64.random(in: 0...max(1, backoff / 4)); updated.lastError = reason
        try session.write { try journal.put(entry: updated) }
        log.info("archive_upload stage=retryable attempt=\(updated.retryCount) reason=\(reason)", subsystems: .mls)
    }
    nonisolated private static func apiError(_ error: Error) -> ErmisApiError? {
        (error as? ErmisApiError) ?? ((error as? ClientError)?.underlyingError as? ErmisApiError)
    }
    private func classify(_ item: RecoveryJournalEntry, error: Error, retryReason: String = "network_or_storage_error") throws {
        var next = item
        if let error = Self.apiError(error), error.code == 6 {
            next.status = "permission_denied"; next.lastError = "permission_denied"
        } else if let error = Self.apiError(error), (400..<500).contains(error.httpStatusCode), ![408, 429, 401].contains(error.httpStatusCode) {
            next.status = item.scope == "group_sponsored" && [404, 405].contains(error.httpStatusCode) ? "unsupported" : "terminal"
            next.lastError = "server_\(error.code)"
        } else { try retry(item, reason: retryReason); return }
        try session.write { try journal.put(entry: next) }
        log.info("archive_upload stage=\(next.status)", subsystems: .mls)
    }
    private func materialize(_ item: RecoveryJournalEntry) async throws {
        do {
            let cp = try JSONDecoder().decode(ArchiveCheckpoint.self, from: item.payload)
            let uploadKey = "upload:\(item.key):\(cp.blobId)"
            if try journal.get(key: uploadKey) != nil { var next = item; next.status = "materialized"; try session.write { try journal.put(entry: next) }; return }
            guard let vaultBytes = vault?["vault_bytes"].bytes else { try retry(item, reason: "waiting_public_key"); return }
            let metadata = try recoveryVaultMetadata(vault: vaultBytes)
            var recipients: [E2eeArchiveWire]
            var recipientHash: String?
            if item.scope == "account_owned" {
                recipients = [.object(["user_id": .string(userId), "recovery_key_id": .string(metadata.keyId), "public_key": .bytes(metadata.publicKey), "ciphersuite": .uint(UInt64(metadata.ciphersuite))])]
            } else {
                if cp.sponsorRole == "backup" {
                    if Self.now() < item.createdAt + 5_000 {
                        var next = item; next.nextRetryAt = item.createdAt + 5_000; try session.write { try journal.put(entry: next) }; return
                    }
                    let members = try JSONDecoder().decode(E2eeArchiveWire.self, from: cp.snapshot)["members"].array.sorted {
                        let left = $0["user_id"].string ?? ""; let right = $1["user_id"].string ?? ""
                        return left == right ? ($0["leaf_index"].number ?? .max) < ($1["leaf_index"].number ?? .max) : left < right
                    }
                    guard let selected = members.first(where: { $0["user_id"].string != cp.primaryUser }),
                          selected["user_id"].string == userId, selected["leaf_index"].number == cp.ownLeafIndex.map(UInt64.init) else {
                        var next = item; next.status = "unsupported"; next.lastError = "not_designated_backup"
                        try session.write { try journal.put(entry: next) }; return
                    }
                }
                let result = try await request(.epochArchive(cid: ChannelId(cid: item.cid), operation: .recipients,
                    body: .object(["group_generation": .uint(item.groupGeneration), "epoch": .uint(item.epoch)])))
                if result["matching_candidate_exists"].boolean {
                    var ack = item; ack.key = "ack:\(item.key)"; ack.kind = "ack"; ack.status = "covered"; ack.payload = Data(); ack.lastError = nil
                    try session.write { try journal.put(entry: ack); try journal.remove(key: item.key) }; return
                }
                if ["policy_disabled", "recipient_limit"].contains(result["reason"].string ?? "") {
                    var next = item; next.status = "unsupported"; next.lastError = result["reason"].string
                    try session.write { try journal.put(entry: next) }; return
                }
                recipients = result["recipients"].array
                guard !recipients.isEmpty else { try retry(item, reason: "waiting_recipients"); return }
                recipientHash = result["recipient_set_hash"].string
                guard recipientHash != nil else { throw E2eeArchiveError.invalidData }
            }
            var archive = try keys.open(cp.archive, purpose: "archive:\(item.cid):\(item.groupGeneration):\(item.epoch)")
            defer { archive.resetBytes(in: 0..<archive.count) }
            var blob = try sealRecoveryArchive(archive: archive, cid: item.cid, groupGeneration: item.groupGeneration,
                epoch: item.epoch, scope: item.scope, blobId: cp.blobId, snapshotHash: cp.hash)
            defer { blob.adk.resetBytes(in: 0..<blob.adk.count) }
            let wraps = try recipients.map { recipient -> E2eeArchiveWire in
                guard let publicKey = recipient["public_key"].bytes, let keyId = recipient["recovery_key_id"].string,
                      let userId = recipient["user_id"].string, recipient["ciphersuite"].number == 3 else { throw E2eeArchiveError.invalidData }
                let wrap = try wrapRecoveryArchiveKey(adk: blob.adk, publicKey: publicKey, cid: item.cid,
                    groupGeneration: item.groupGeneration, epoch: item.epoch, scope: item.scope, blobId: cp.blobId,
                    snapshotHash: cp.hash, keyId: keyId)
                return .object(["recipient_user_id": .string(userId), "recipient_recovery_key_id": .string(keyId),
                    "hpke_kem_output": .bytes(wrap.kemOutput), "hpke_ciphertext": .bytes(wrap.ciphertext),
                    "hpke_info": .bytes(wrap.hpkeInfo), "ciphersuite": .uint(UInt64(wrap.ciphersuite))])
            }
            var body: [String: E2eeArchiveWire] = ["group_generation": .uint(item.groupGeneration), "epoch": .uint(item.epoch),
                "archive_blob_id": .string(cp.blobId), "idempotency_key": .string(cp.blobId), "scope": .string(item.scope),
                "encrypted_archive": .object(["ciphertext": .bytes(blob.ciphertext), "nonce": .bytes(blob.nonce), "aead_aad": .bytes(blob.aeadAad)]),
                "snapshot": .object(["snapshot_bytes": .bytes(cp.snapshot), "snapshot_hash": .string(cp.hash)]), "wraps": .array(wraps)]
            if let recipientHash { body["recipient_set_hash"] = .string(recipientHash) }
            var upload = item; upload.key = uploadKey; upload.kind = "upload"; upload.status = "queued"
            upload.payload = try JSONEncoder().encode(E2eeArchiveWire.object(body)); upload.retryCount = 0; upload.nextRetryAt = 0
            var next = item; next.status = "materialized"
            try session.write { _ = try journal.insertIfAbsent(entry: upload); try journal.put(entry: next) }
            log.info("archive_upload stage=queued epoch=\(item.epoch) scope=\(item.scope)", subsystems: .mls)
        } catch { try classify(item, error: error) }
    }
    private func upload(_ item: RecoveryJournalEntry) async throws {
        let body = try JSONDecoder().decode(E2eeArchiveWire.self, from: item.payload)
        let cpKey = String(item.key.dropFirst("upload:".count).split(separator: ":").dropLast().joined(separator: ":"))
        do {
            let result = try await request(.epochArchive(cid: ChannelId(cid: item.cid), operation: .upload, body: body))
            let cpRow = try journal.get(key: cpKey)
            let reason = result["reason_code"].string
            if reason == "recipient_set_stale", item.scope == "group_sponsored", var cpRow {
                var cp = try JSONDecoder().decode(ArchiveCheckpoint.self, from: cpRow.payload)
                cp.blobId = UUID().uuidString.lowercased(); cp.rewraps += 1
                cpRow.payload = try JSONEncoder().encode(cp); cpRow.status = cp.rewraps <= 2 ? "queued" : "terminal"; cpRow.nextRetryAt = 0
                try session.write { try journal.put(entry: cpRow); try journal.remove(key: item.key) }; return
            }
            if reason == "sponsored_disabled", item.scope == "group_sponsored" {
                var next = item; next.status = "unsupported"; next.lastError = reason
                try session.write { try journal.put(entry: next) }; return
            }
            let ackStatus: String
            switch reason { case "stored": ackStatus = "uploaded"; case "idempotent": ackStatus = "idempotent"; case "duplicate_cap": ackStatus = "duplicate_cap"; default: throw E2eeArchiveError.invalidData }
            var ack = item; ack.key = "ack:\(cpKey)"; ack.kind = "ack"; ack.status = ackStatus; ack.nextRetryAt = 0; ack.createdAt = Self.now()
            var updated = cpRow; updated?.status = "uploaded"
            try session.write { try journal.commitUpload(pendingKey: item.key, ack: ack, checkpoint: updated); if let cpRow { try journal.remove(key: cpRow.key) } }
            log.info("archive_upload stage=acknowledged epoch=\(item.epoch) result=\(ackStatus)", subsystems: .mls)
        } catch { try classify(item, error: error) }
    }
    public func retryBlockedArchiveUploads(cid: String) async throws -> Int {
        let count = try await serialized { try await self.unpause(cid) }
        resume(); return count
    }
    private func unpause(_ cid: String) throws -> Int {
        var count = 0
        for kind in ["checkpoint", "upload"] {
            var after: String?
            while true {
                let items = try journal.page(kind: kind, status: "permission_denied", now: .max, cid: cid, afterKey: after, limit: 50)
                if items.isEmpty { break }; after = Self.cursor(items.last!)
                for var item in items { item.status = "queued"; item.nextRetryAt = 0; item.lastError = nil; try session.write { try journal.put(entry: item) }; count += 1 }
            }
        }
        return count
    }

    public func enqueueRestore(cid: String, fromEpoch: UInt64? = nil, toEpoch: UInt64? = nil) async {
        do {
            try await enqueueRestoreDurably(cid: cid, fromEpoch: fromEpoch, toEpoch: toEpoch)
        } catch { publish("retryable_error", cid: cid, reason: "journal_or_device_key_unavailable") }
    }
    /// Returns only after the account-fenced journal write commits. Failure must keep the host's queue request pending.
    public func enqueueRestoreDurably(cid: String, fromEpoch: UInt64? = nil, toEpoch: UInt64? = nil, requestId: String? = nil) async throws {
        try await serialized { try await self.queueRestore(cid, from: fromEpoch, to: toEpoch, requestId: requestId) }
        resume()
    }
    private func queueRestore(_ cid: String, from: UInt64?, to: UInt64?, requestId: String?) throws {
        let gen = try generation(cid); let key = "restore:\(cid):\(gen)"
        let saved = try journal.get(key: key)
        // Keep code6 paused for automatic incidents; explicit repair/new login can recheck.
        if requestId == nil && saved?.status == "permission_denied" { return }
        let existing = try saved.map { try JSONDecoder().decode(ArchiveRestoreJob.self, from: $0.payload) }
        // Automatic incidents carry a range, not evidence of new material. Preserve a
        // completed contained attempt, including its gaps; explicit repair/new login retries.
        if requestId == nil, let existing, existing.validatorVersion == 2, existing.coverageVersion == 2,
           saved?.status == "coverage_unknown",
           existing.from.map({ old in from.map { old <= $0 } ?? false }) ?? true,
           existing.to.map({ old in to.map { old >= $0 } ?? false }) ?? true { return }
        if let requestId, existing?.requestId == requestId, existing?.validatorVersion == 2, existing?.from == from, existing?.to == to,
           !["done","done_with_gaps","coverage_unknown"].contains(saved?.status ?? "") || existing?.coverageVersion == 2 { return }
        let decodedPrior = try saved.flatMap { ["done", "done_with_gaps", "coverage_unknown", "superseded", "permission_denied", "terminal"].contains($0.status) ? nil : try JSONDecoder().decode(ArchiveRestoreJob.self, from: $0.payload) }
        let prior = decodedPrior?.validatorVersion == 2 && (requestId == nil || existing?.requestId == requestId) ? decodedPrior : nil
        let mergedFrom = prior.map { previous in previous.from.flatMap { old in from.map { min(old, $0) } } } ?? from
        let mergedTo = prior.map { previous in previous.to.flatMap { old in to.map { max(old, $0) } } } ?? to
        // New incidents rescan completed epochs; network retries retain this cycle's cursor.
        let job = ArchiveRestoreJob(from: mergedFrom, to: mergedTo, cycle: prior?.cycle ?? UUID().uuidString, requestId: requestId ?? prior?.requestId)
        try session.write { try journal.put(entry: Self.entry(key, kind: "restore", cid: cid, generation: gen, payload: try JSONEncoder().encode(job))) }
    }
    public func repairRecoveryChannel(cid: String) async throws {
        try await serialized { await self.restore(cid, from: nil, to: nil, manual: true) }
    }
    private func resumeRestores() {
        for state in ["requires_pin", "retryable_error"] {
            var after: String?
            while let items = try? journal.page(kind: "restore", status: state, now: .max, cid: nil, afterKey: after, limit: 50), !items.isEmpty {
                after = Self.cursor(items.last!)
                for var item in items { item.status = "queued"; item.nextRetryAt = 0; try? session.write { try journal.put(entry: item) } }
            }
        }
        resume()
    }
    public func loadRestoreProgress(cid: String) throws -> E2eeArchiveRecoveryStatus {
        guard let saved = try journal.get(key: "restore:\(cid):\(generation(cid))") else { return latest }
        let job = try JSONDecoder().decode(ArchiveRestoreJob.self, from: saved.payload)
        let unproven = saved.status == "done" && (job.coverage != "covered" || job.coverageVersion != 2)
        return .init(hasVault: latest.hasVault, unlocked: latest.unlocked, state: unproven ? "coverage_unknown" : saved.status, cid: cid,
            restoredMessages: latest.restoredMessages, reason: unproven ? "coverage_unknown" : saved.lastError, requiresPinChannels: pendingPinChannels, pinRequestRevision: latest.pinRequestRevision)
    }
    private func restore(_ cid: String, from: UInt64?, to: UInt64?, manual: Bool, requestedCycle: String? = nil) async {
        guard let gen = try? generation(cid) else { publish("retryable_error", cid: cid, reason: "storage_or_discovery"); return }
        let cycle = requestedCycle ?? UUID().uuidString
        var epochInFlight: UInt64?
        do {
            let jobKey = "restore:\(cid):\(gen)"
            let existing = try journal.get(key: jobKey).map { try JSONDecoder().decode(ArchiveRestoreJob.self, from: $0.payload) }
            let requestId = existing?.cycle == cycle ? existing?.requestId : nil
            let job = ArchiveRestoreJob(from: from, to: to, cycle: cycle, requestId: requestId)
            try session.write { try journal.put(entry: Self.entry(jobKey, kind: "restore", cid: cid, generation: gen, payload: try JSONEncoder().encode(job))) }
            try await loadVault()
            guard var privateKey = try cachedKey() else {
                try session.write { try journal.put(entry: Self.entry(jobKey, kind: "restore", cid: cid, generation: gen, payload: try JSONEncoder().encode(job), status: "requires_pin")) }
                if manual { latest.pinRequestRevision &+= 1 }
                pendingPinChannels.insert(cid); publish("requires_pin", cid: cid, reason: "unlock_recovery_vault"); return
            }
            defer { privateKey.resetBytes(in: 0..<privateKey.count) }
            var restored = 0; var gaps = false; var availabilityCursor: String?
            var summaryReason: String?; var archiveEpochs = Set<UInt64>()
            var availabilityPages = 0; var availabilityCursors = Set<String>()
            publish("restoring", cid: cid)
            repeat {
                var body: [String: E2eeArchiveWire] = ["group_generation": .uint(gen), "limit": .uint(100)]
                if let availabilityCursor { body["cursor"] = .string(availabilityCursor) }
                let available = try await request(.epochArchive(cid: ChannelId(cid: cid), operation: .availability, body: .object(body)))
                availabilityPages += 1
                guard availabilityPages <= 1000, available["epochs"].array.count <= 100 else { throw E2eeArchiveError.invalidData }
                for record in available["epochs"].array {
                    guard let epoch = record["epoch"].number, record["group_generation"].number ?? 0 == gen,
                          from.map({ epoch >= $0 }) ?? true, to.map({ epoch <= $0 }) ?? true else { continue }
                    archiveEpochs.insert(epoch)
                }
                guard archiveEpochs.count <= 100_000 else { throw E2eeArchiveError.invalidData }
                if available["has_more"].boolean {
                    guard let cursor = available["next_cursor"].string, availabilityCursors.insert(cursor).inserted else { throw E2eeArchiveError.invalidData }
                    availabilityCursor = cursor
                } else { availabilityCursor = nil }
            } while availabilityCursor != nil
            let census = try await census(cid, gen: gen, from: from ?? 0, to: to ?? 1000, cycle: cycle)
            try activeRestore(cid, gen)
            let coverage = census.state == "covered" && to != nil ? "covered" : "coverage_unknown"
            summaryReason = census.reason
            var restoreCalls=0;var restoreBytes=0;var restoreDistinct=0
            for epoch in archiveEpochs.union(census.ids.keys).sorted() {
                    try activeRestore(cid, gen)
                    epochInFlight = epoch
                    let epochKey = "restore_epoch:\(cid):\(gen):\(epoch)"
                    let saved = try journal.get(key: epochKey)
                    let decoded = try saved.map { try JSONDecoder().decode(ArchiveRestoreProgress.self, from: $0.payload) }
                    let progress = decoded?.cycle == cycle && decoded?.validatorVersion == 2 && decoded?.coverageVersion == 1 ? decoded : nil
                    if !manual, progress != nil, let saved, ["done", "done_with_gaps"].contains(saved.status) { gaps = gaps || saved.status == "done_with_gaps"; continue }
                    restoreCalls += 1;guard restoreCalls<=1000 else {throw E2eeArchiveError.discoveryBudget}
                    let material = try await request(.epochArchive(cid: ChannelId(cid: cid), operation: .material,
                        body: .object(["group_generation": .uint(gen), "epoch_from": .uint(epoch), "epoch_to": .uint(epoch), "include_snapshots": .bool(true), "include_wraps": .bool(true)])))
                    let materialBytes=try JSONEncoder().encode(material).count;restoreBytes += materialBytes
                    guard materialBytes<=8 * 1024 * 1024,restoreBytes<=64 * 1024 * 1024 else {throw E2eeArchiveError.discoveryBudget}
                    var messageCursor = manual ? nil : progress?.cursor
                    var count = progress?.restored ?? 0; var epochGaps = progress?.hasGaps ?? false
                    var reasons = progress?.reasons ?? [:]; var outcomes = progress?.outcomes ?? [:]
                    var discovered = progress?.discovered ?? 0; var safeSkipped = progress?.safeSkipped ?? 0
                    restoreDistinct += discovered
                    var cryptoSuccess = progress?.cryptoSuccess ?? 0
                    var pageCursors = Set<String>(); var epochPages = 0; var epochBytes = 0
                    func gap(_ reason: String) { epochGaps = true; reasons[reason, default: 0] += 1 }
                    var prepared = [String: Data]()
                    defer { for key in Array(prepared.keys) { if var value = prepared.removeValue(forKey: key) { value.resetBytes(in: 0..<value.count) } } }
                    var hasMore: Bool
                    repeat {
                        var query: [String: E2eeArchiveWire] = ["group_generation": .uint(gen), "epoch_from": .uint(epoch), "epoch_to": .uint(epoch), "limit": .uint(100)]
                        if let messageCursor { query["cursor"] = messageCursor }
                        restoreCalls += 1;guard restoreCalls<=1000,epochPages<50 else {throw E2eeArchiveError.discoveryBudget}
                        let page: E2eeArchiveWire
                        do { page = try await request(.epochArchive(cid: ChannelId(cid: cid), operation: .ciphertexts, body: .object(query))) }
                        catch {
                            if messageCursor != nil, let api = Self.apiError(error), api.code != 6, (400..<500).contains(api.httpStatusCode), ![401,408,429].contains(api.httpStatusCode) {
                                try recordEpochFailure(cid,gen,epoch,cycle,"cursor_rejected","coverage_unknown")
                                throw E2eeArchiveError.cursorRejected
                            }
                            throw error
                        }
                        try activeRestore(cid, gen)
                        let pageBytes=try JSONEncoder().encode(page).count;epochPages += 1;epochBytes += pageBytes;restoreBytes += pageBytes
                        guard epochBytes<=64 * 1024 * 1024,restoreBytes<=64 * 1024 * 1024,page["ciphertexts"].array.count<=100 else {throw E2eeArchiveError.discoveryBudget}
                        for message in page["ciphertexts"].array {
                            guard let id = message["message_id"].string, !id.isEmpty else { throw E2eeArchiveError.invalidData }
                            if outcomes[id] != nil { continue }
                            restoreDistinct += 1;guard restoreDistinct<=5000 else {throw E2eeArchiveError.discoveryBudget}
                            discovered += 1
                            guard message["group_generation"].number ?? 0 == gen, message["mls_epoch"].number == epoch else { gap("aad"); outcomes[id] = "aad"; continue }
                            var recovered = false; var failureReason = "material_unavailable"
                            for blob in material["blobs"].array.sorted(by: { ($0["archive_scope"].string == "group_sponsored" ? 0 : 1) < ($1["archive_scope"].string == "group_sponsored" ? 0 : 1) }) {
                                guard blob["cid"].string == cid, blob["epoch"].number == epoch,
                                      let blobId = blob["archive_blob_id"].string, let hash = blob["member_snapshot_hash"].string else { continue }
                                failureReason = "wrap_unavailable"
                                guard let wrap = material["wraps"].array.first(where: { $0["archive_blob_id"].string == blobId && $0["recipient_user_id"].string == userId && $0["recipient_recovery_key_id"].string == vault?["recovery_key_id"].string }) else { continue }
                                failureReason = "snapshot_unavailable"
                                guard let snapshot = material["snapshots"][hash]["snapshot_bytes"].bytes else { continue }
                                do {
                                    failureReason = "snapshot"
                                    guard Self.hex(Data(SHA256.hash(data: snapshot))) == hash,
                                          let aadBytes = blob["aead_aad"].bytes, let hpkeInfo = wrap["hpke_info"].bytes,
                                          let ciphertext = blob["encrypted_archive_bytes"].bytes, let nonce = blob["aead_nonce"].bytes,
                                          let kem = wrap["hpke_kem_output"].bytes, let wrapped = wrap["hpke_ciphertext"].bytes,
                                          wrap["ciphersuite"].number == 3 else { throw E2eeArchiveError.invalidData }
                                    let aad = try JSONDecoder().decode(E2eeArchiveWire.self, from: aadBytes)
                                    let info = try JSONDecoder().decode(E2eeArchiveWire.self, from: hpkeInfo)
                                    guard aad["cid"].string == cid, aad["epoch"].number == epoch, aad["group_generation"].number ?? 0 == gen,
                                          aad["snapshot_hash"].string == hash, aad["blob_id"].string == blobId,
                                          aad["scope"].string == blob["archive_scope"].string, info["recipient_key_id"].string == vault?["recovery_key_id"].string else { throw E2eeArchiveError.invalidData }
                                    failureReason = "wrap"
                                    let archive: Data
                                    if let cached = prepared[blobId] { archive = cached }
                                    else {
                                        archive = try openRecoveryArchive(privateKey: privateKey,
                                            blob: RecoveryArchiveBlob(ciphertext: ciphertext, nonce: nonce, aeadAad: aadBytes, adk: Data()),
                                            wrap: RecoveryArchiveWrap(kemOutput: kem, ciphertext: wrapped, ciphersuite: 3, hpkeInfo: hpkeInfo))
                                        prepared[blobId] = archive
                                    }
                                    failureReason = "crypto"
                                    try activeRestore(cid, gen); try apply(cid, gen, archive, snapshot, message); try activeRestore(cid, gen)
                                    cryptoSuccess += 1; recovered = true; count += 1; restored += 1; outcomes[id] = "persisted"; break
                                } catch E2eeArchiveError.safeSkipped { cryptoSuccess += 1; recovered = true; safeSkipped += 1; outcomes[id] = "safe_skipped"; break }
                                catch E2eeArchiveError.storageFailure { throw E2eeArchiveError.storageFailure }
                                catch E2eeArchiveError.generationChanged { throw E2eeArchiveError.generationChanged }
                                catch E2eeArchiveError.sessionEnded { throw E2eeArchiveError.sessionEnded }
                                catch is E2eeMessageAADError { cryptoSuccess += 1; failureReason = "aad"; break }
                                catch is DecodingError { if failureReason == "crypto" { cryptoSuccess += 1; failureReason = "payload_schema" }; break }
                                catch is E2eeAttachmentManifestValidationError { cryptoSuccess += 1; failureReason = "payload_schema"; break }
                                catch { continue }
                            }
                            if !recovered { gap(failureReason); outcomes[id] = failureReason }
                        }
                        hasMore = page["has_more"].boolean
                        if !hasMore {
                            for id in census.ids[epoch] ?? [] where outcomes[id]==nil {discovered += 1;gap("discovery_gap");outcomes[id]="discovery_gap"}
                        }
                        var invalidCursor = false
                        if hasMore {
                            if let next = page["next_cursor"]["last_event_key"].string,
                               next != messageCursor?["last_event_key"].string, pageCursors.insert(next).inserted {} else { invalidCursor = true; gap("cursor_rejected") }
                        }
                        if !invalidCursor { messageCursor = hasMore ? page["next_cursor"] : nil }
                        let epochCoverage:String
                        if hasMore || invalidCursor || reasons["discovery_gap"] != nil {epochCoverage="coverage_unknown"}
                        else if !epochGaps {epochCoverage="covered"}
                        else if ["aad","payload_schema","crypto","wrap","snapshot"].contains(where:{reasons[$0] != nil}) {epochCoverage="validation_gap"}
                        else if reasons["material_unavailable"] != nil && !archiveEpochs.contains(epoch) {epochCoverage="archive_missing"}
                        else {epochCoverage="coverage_unknown"}
                        let progress = ArchiveRestoreProgress(cursor: messageCursor, restored: count, hasGaps: epochGaps, cycle: cycle,
                            discovered: discovered, safeSkipped: safeSkipped, reasons: reasons, outcomes: outcomes, cryptoSuccess: cryptoSuccess, coverage: epochCoverage, coverageVersion: 1)
                        let state = invalidCursor ? "coverage_unknown" : hasMore ? "restoring" : epochGaps ? "done_with_gaps" : "done"
                        try session.write { try activeRestore(cid, gen); try journal.put(entry: Self.entry(epochKey, kind: "restore_epoch", cid: cid, generation: gen, epoch: epoch, payload: try JSONEncoder().encode(progress), status: state)) }
                        if invalidCursor { throw E2eeArchiveError.cursorRejected }
                        if hasMore && (epochPages>=50 || restoreDistinct>=5000) {throw E2eeArchiveError.discoveryBudget}
                    } while hasMore
                    gaps = gaps || epochGaps
                    if epochGaps && summaryReason == nil { summaryReason = reasons.keys.sorted().first }
            }
            epochInFlight = nil
            let state = coverage != "covered" ? "coverage_unknown" : gaps ? "done_with_gaps" : "done"
            let reason = summaryReason ?? (coverage != "covered" ? "coverage_unknown" : nil)
            let finished = ArchiveRestoreJob(from: from, to: to, cycle: cycle, coverage: coverage, coverageVersion: 2, requestId: requestId)
            var row = Self.entry(jobKey, kind: "restore", cid: cid, generation: gen, payload: try JSONEncoder().encode(finished), status: state)
            row.lastError = reason
            try session.write { try activeRestore(cid, gen); try journal.put(entry: row) }
            pendingPinChannels.remove(cid); publish(state, cid: cid, reason: reason, restored: restored)
        } catch {
            guard (try? active()) != nil else { return }
            if (error as? E2eeArchiveError) == .discoveryBudget {
                if let epochInFlight { try? recordEpochFailure(cid, gen, epochInFlight, cycle, "discovery_budget", "coverage_unknown") }
                if var old = try? journal.get(key:"restore:\(cid):\(gen)") {
                    old.status="coverage_unknown";old.lastError="discovery_budget"
                    if var incomplete=try? JSONDecoder().decode(ArchiveRestoreJob.self,from:old.payload) {
                        incomplete.coverage="coverage_unknown";incomplete.coverageVersion=2
                        if let payload=try? JSONEncoder().encode(incomplete) {old.payload=payload}
                    }
                    try? session.write {try activeRestore(cid,gen);try journal.put(entry:old)}
                }
                publish("coverage_unknown",cid:cid,reason:"discovery_budget");return
            }
            if (error as? E2eeArchiveError) == .cursorRejected {
                if var old = try? journal.get(key: "restore:\(cid):\(gen)") {
                    old.status = "coverage_unknown"; old.lastError = "cursor_rejected"
                    if var incomplete=try? JSONDecoder().decode(ArchiveRestoreJob.self,from:old.payload) {
                        incomplete.coverage="coverage_unknown";incomplete.coverageVersion=2
                        if let payload=try? JSONEncoder().encode(incomplete) {old.payload=payload}
                    }
                    try? session.write { try activeRestore(cid, gen); try journal.put(entry: old) }
                }
                publish("coverage_unknown", cid: cid, reason: "cursor_rejected"); return
            }
            if (error as? E2eeArchiveError) == .generationChanged {
                if var old = try? journal.get(key: "restore:\(cid):\(gen)") {
                    old.status = "superseded"; old.lastError = "generation_changed"
                    try? session.write { try journal.put(entry: old) }
                }
                return
            }
            do {
                if let item = try? journal.get(key: "restore:\(cid):\(gen)") {
                    let reason: String
                    if let api = Self.apiError(error) { reason = api.code == 6 ? "permission_denied" : api.httpStatusCode == 401 ? "authorization" : "network" }
                    else { reason = (error as? E2eeArchiveError) == .storageFailure ? "storage" : "discovery" }
                    if let epochInFlight { try? recordEpochFailure(cid, gen, epochInFlight, cycle, reason, "queued") }
                    if Self.apiError(error) != nil { try? classify(item, error: error, retryReason: reason) }
                    else { try? retry(item, reason: reason) }
                } else if let item = try? row("restore:\(cid):\(gen)", kind: "restore", cid: cid, generation: gen, payload: Self.jobWire(from: from, to: to)) {
                    try? retry(item, reason: "network_storage_or_device_key_unavailable")
                }
            }
            if let saved = try? journal.get(key: "restore:\(cid):\(gen)") {
                pendingPinChannels.remove(cid)
                publish(saved.status, cid: cid, reason: saved.lastError)
            } else { publish("retryable_error", cid: cid, reason: "storage_or_discovery") }
        }
    }

    private func recordEpochFailure(_ cid: String, _ gen: UInt64, _ epoch: UInt64, _ cycle: String, _ reason: String, _ state: String) throws {
        try activeRestore(cid, gen)
        let key = "restore_epoch:\(cid):\(gen):\(epoch)"
        let old = try journal.get(key: key).flatMap { try JSONDecoder().decode(ArchiveRestoreProgress.self, from: $0.payload) }
        var progress = old.flatMap { $0.cycle == cycle && $0.validatorVersion == 2 ? $0 : nil }
            ?? ArchiveRestoreProgress(cursor: nil, restored: 0, hasGaps: false, cycle: cycle)
        var reasons = progress.reasons ?? [:]; reasons[reason, default: 0] += 1
        progress.reasons = reasons; progress.coverage = "coverage_unknown"; progress.coverageVersion = 1
        var row = Self.entry(key, kind: "restore_epoch", cid: cid, generation: gen, epoch: epoch, payload: try JSONEncoder().encode(progress), status: state)
        row.lastError = reason
        try session.write { try activeRestore(cid, gen); try journal.put(entry: row) }
    }

    private func census(_ cid: String, gen: UInt64, from: UInt64, to: UInt64, cycle: String) async throws -> ArchiveCensus {
        let key = "restore_census:\(cid):\(gen)"
        let saved = try journal.get(key: key).map { try JSONDecoder().decode(ArchiveCensus.self, from: $0.payload) }
        var state = saved.flatMap { $0.version == 2 && $0.cycle == cycle && $0.from == from && $0.to == to ? $0 : nil }
            ?? ArchiveCensus(from: from, to: to, cycle: cycle)
        func save() throws { try session.write { try journal.put(entry: Self.entry(key, kind: "restore_census", cid: cid, generation: gen, payload: try JSONEncoder().encode(state), status: state.state)) } }
        guard state.state == "discovering" else { return state }
        guard to >= from, to - from <= 1000 else { state.state = "coverage_unknown"; state.reason = "discovery_range"; try save(); return state }
        var cursors = Set<String>()
        var ids = state.ids.mapValues { Set($0) }
        do {
            while state.state == "discovering" {
                guard state.pages < 50 else { state.state = "coverage_unknown"; state.reason = "discovery_budget"; break }
                var query: [String: E2eeArchiveWire] = ["group_generation": .uint(gen), "epoch_from": .uint(from), "epoch_to": .uint(to), "limit": .uint(100)]
                if let cursor = state.cursor { query["cursor"] = cursor }
                let page = try await request(.epochArchive(cid: ChannelId(cid: cid), operation: .ciphertexts, body: .object(query)))
                try activeRestore(cid, gen)
                let bytes = try JSONEncoder().encode(page).count
                guard page["ciphertexts"].array.count <= 100, state.bytes + bytes <= 16 * 1024 * 1024 else {
                    state.state = "coverage_unknown"; state.reason = "discovery_budget"; break
                }
                for message in page["ciphertexts"].array {
                    guard message["group_generation"].number ?? 0 == gen, let epoch = message["mls_epoch"].number, epoch >= from, epoch <= to,
                          let id = message["message_id"].string, !id.isEmpty else { throw E2eeArchiveError.invalidData }
                    let route = message["cid"].string ?? cid
                    guard route == cid || message["parent_cid"].string == cid || message["e2ee_group_id"].string == cid else { throw E2eeArchiveError.invalidData }
                    ids[epoch, default: []].insert(id)
                }
                guard ids.values.reduce(0, { $0 + $1.count }) <= 5000 else { throw E2eeArchiveError.invalidData }
                if page["has_more"].boolean {
                    guard let next = page["next_cursor"]["last_event_key"].string, next != state.cursor?["last_event_key"].string,
                          cursors.insert(next).inserted else { throw E2eeArchiveError.invalidData }
                    state.cursor = page["next_cursor"]
                } else { state.cursor = nil; state.state = "covered" }
                state.ids = ids.mapValues { $0.sorted() }; state.pages += 1; state.bytes += bytes
                try save()
            }
        } catch {
            if (error as? E2eeArchiveError) == .generationChanged || (error as? E2eeArchiveError) == .sessionEnded { throw error }
            if let api = Self.apiError(error) {
                if api.code == 6 || !(400..<500).contains(api.httpStatusCode) || [401, 408, 429].contains(api.httpStatusCode) { throw error }
                state.reason = state.cursor == nil ? "discovery_rejected" : "cursor_rejected"
            } else if error is CancellationError { throw error }
            else if (error as? E2eeArchiveError) == nil { throw error }
            else { state.reason = "discovery_budget_or_scope" }
            state.state = "coverage_unknown"
        }
        try save(); return state
    }

    nonisolated private static func jobWire(from: UInt64?, to: UInt64?) throws -> E2eeArchiveWire {
        try JSONDecoder().decode(E2eeArchiveWire.self, from: JSONEncoder().encode(ArchiveRestoreJob(from: from, to: to)))
    }
    private func row(_ key: String, kind: String, cid: String = "", generation: UInt64 = 0, epoch: UInt64 = 0,
        scope: String = "", payload: E2eeArchiveWire, status: String = "queued") throws -> RecoveryJournalEntry {
        Self.entry(key, kind: kind, cid: cid, generation: generation, epoch: epoch, scope: scope, payload: try JSONEncoder().encode(payload), status: status)
    }
    nonisolated private static func entry(_ key: String, kind: String, cid: String = "", generation: UInt64 = 0,
        epoch: UInt64 = 0, scope: String = "", payload: Data, status: String = "queued") -> RecoveryJournalEntry {
        .init(key: key, kind: kind, cid: cid, groupGeneration: generation, epoch: epoch, scope: scope,
            payload: payload, status: status, retryCount: 0, createdAt: now(), nextRetryAt: 0, lastError: nil)
    }
    nonisolated private static func cursor(_ item: RecoveryJournalEntry) -> String { "\(item.nextRetryAt)|\(item.key)" }
    nonisolated private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    nonisolated private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
