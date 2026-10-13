import Foundation
import XCTest
import SQLite3
import open_mls_ios
@testable import ErmisChat

final class E2eeArchiveRecoveryTests: XCTestCase {
    func testVaultKeychainAndArchiveSurviveRestartWithoutPin() throws {
        let namespace = "test-\(UUID().uuidString)"
        let store = E2eeRecoveryKeyStore(namespace: namespace)
        let keys = try generateRecoveryKeys()
        let vault = try createRecoveryVault(pin: "12345678", keys: keys)
        let privateKey = try unlockRecoveryVault(pin: "12345678", vault: vault)
        try store.saveUnlock(privateKey)
        XCTAssertEqual(try E2eeRecoveryKeyStore(namespace: namespace).loadUnlock(), privateKey)
        XCTAssertThrowsError(try unlockRecoveryVault(pin: "87654321", vault: vault))
        let provider = Provider()
        let sender = try Identity(provider: provider, userId: "fixture-sender")
        let cid = "messaging:project:archive-fixture"
        let group = try Group.createWithCid(provider: provider, founder: sender, cid: cid)
        let archive = try group.archiveEpochV2()
        let ciphertext = try group.createMessage(provider: provider, sender: sender, plaintext: Data("device-message".utf8))
        let blob = try sealRecoveryArchive(archive: archive.archiveBytes, cid: cid, groupGeneration: 3, epoch: group.epoch(), scope: "account_owned", blobId: "fixture-blob", snapshotHash: "snapshot")
        let wrap = try wrapRecoveryArchiveKey(adk: blob.adk, publicKey: keys.publicKey, cid: cid, groupGeneration: 3, epoch: group.epoch(), scope: "account_owned", blobId: "fixture-blob", snapshotHash: "snapshot", keyId: keys.keyId)
        let opened = try openRecoveryArchive(privateKey: store.loadUnlock()!, blob: blob, wrap: wrap)
        let decoded = try decryptEpochArchiveV2(provider: provider, archive: opened, snapshot: archive.snapshotBytes, ciphertext: ciphertext, allowOwnMessages: true, maxForwardDistance: 0)
        XCTAssertEqual(String(data: decoded.content, encoding: .utf8), "device-message")
        XCTAssertEqual(group.epoch(), 0)
        try store.clearUnlock(); XCTAssertNil(try store.loadUnlock())
    }
    func testJournalReopenPreservesRequestAndCommitsAckAtomically() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString).db").path
        func row(_ key: String) -> RecoveryJournalEntry { .init(key: key, kind: "upload", cid: "messaging:test", groupGeneration: 3, epoch: 7, scope: "account_owned", payload: Data([1,2,3]), status: "queued", retryCount: 0, createdAt: 1, nextRetryAt: 0, lastError: nil) }
        do { let journal = try RecoveryJournal(path: path); XCTAssertTrue(try journal.insertIfAbsent(entry: row("pending"))) }
        let journal = try RecoveryJournal(path: path)
        XCTAssertEqual(try journal.get(key: "pending")?.payload, Data([1,2,3]))
        var ack = row("ack"); ack.kind = "ack"; ack.status = "uploaded"
        var bad = row("checkpoint"); bad.kind = "checkpoint"; bad.scope = "group_sponsored"
        XCTAssertThrowsError(try journal.commitUpload(pendingKey: "pending", ack: ack, checkpoint: bad))
        XCTAssertNil(try journal.get(key: "ack")); XCTAssertNotNil(try journal.get(key: "pending"))
        try journal.commitUpload(pendingKey: "pending", ack: ack, checkpoint: nil)
        XCTAssertNil(try journal.get(key: "pending")); XCTAssertEqual(try journal.get(key: "ack")?.status, "uploaded")
    }
    func testWirePreservesGenerationAndFractionalUserMetadata() throws {
        let json = Data(#"{"group_generation":9007199254740993,"user":{"score":1.25},"vault_bytes":[0,255]}"#.utf8)
        let wire = try JSONDecoder().decode(E2eeArchiveWire.self, from: json)
        XCTAssertEqual(wire["group_generation"].number, 9_007_199_254_740_993)
        XCTAssertEqual(wire["vault_bytes"].bytes, Data([0,255]))
        XCTAssertNoThrow(try JSONEncoder().encode(wire))
    }
    func testLogoutFencesWritesAndClearsOnlyUnlock() throws {
        let keys = E2eeRecoveryKeyStore(namespace: "test-\(UUID().uuidString)")
        let session = E2eeArchiveSession()
        let protected = try keys.protect(Data([1,2,3]), purpose: "backlog")
        try keys.saveUnlock(Data([9]))
        try session.stop { try keys.clearUnlock() }
        XCTAssertThrowsError(try session.write { try keys.saveUnlock(Data([7])) })
        XCTAssertNil(try keys.loadUnlock())
        XCTAssertEqual(try keys.open(protected, purpose: "backlog"), Data([1,2,3]))
    }
}


private actor ArchiveControlFixture {
    let vault: E2eeArchiveWire
    let failure: ErmisErrorType
    var uploads: [Data] = []
    init(vault: Data, keyId: String, failure: ErmisErrorType) {
        self.vault = .object(["vault_bytes": .bytes(vault), "revision": .uint(1), "recovery_key_id": .string(keyId)])
        self.failure = failure
    }
    func request(_ endpoint: Endpoint<E2eeArchiveWire>) throws -> E2eeArchiveWire {
        switch endpoint.path {
        case .recoveryVault: return vault
        case .epochArchive(_, .recipients): return .object(["recipients": .array([]), "reason": .string("recipient_limit")])
        case .epochArchive(_, .upload):
            guard let wire = endpoint.body as? E2eeArchiveWire else { throw E2eeArchiveError.invalidData }
            uploads.append(try JSONEncoder().encode(wire))
            if uploads.count == 1 { throw ClientError(with: ErmisApiError(type: failure, statusCode: failure == .noPermission ? 403 : 503, message: "fixture-transient")) }
            return .object(["status": .string("duplicate"), "reason_code": .string("idempotent")])
        default: throw E2eeArchiveError.invalidData
        }
    }
    func requests() -> [E2eeArchiveWire] { uploads.compactMap { try? JSONDecoder().decode(E2eeArchiveWire.self, from: $0) } }
}

extension E2eeArchiveRecoveryTests {
    func testDurableRestoreEnqueueRejectsJournalFailureAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enqueue-\(UUID().uuidString)")
        let namespace = "test-\(UUID().uuidString)"
        let cid = "messaging:project:enqueue-fixture"
        let recovery = try E2eeArchiveRecovery(namespace: namespace, root: root, userId: "fixture-sender", api: nil,
            isCurrentAccount: { true }, generation: { _ in 3 }, apply: { _, _, _, _, _ in },
            requestOverride: { _ in throw E2eeArchiveError.invalidData })
        defer { try? recovery.stop(clearUnlock: false) }
        let path = root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            XCTFail("Cannot open isolated journal fixture"); throw E2eeArchiveError.invalidData
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER fail_restore BEFORE INSERT ON recovery_work WHEN NEW.kind='restore' BEGIN SELECT RAISE(ABORT,'fixture write failure'); END", nil, nil, nil), SQLITE_OK)
        var rejected = false
        do { try await recovery.enqueueRestoreDurably(cid: cid) } catch { rejected = true }
        XCTAssertTrue(rejected, "Host must observe a failed journal commit")
        let journal = try RecoveryJournal(path: path)
        XCTAssertNil(try journal.get(key: "restore:\(cid):3"))
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER fail_restore", nil, nil, nil), SQLITE_OK)
        try await recovery.enqueueRestoreDurably(cid: cid)
        XCTAssertNotNil(try RecoveryJournal(path: path).get(key: "restore:\(cid):3"))
        try recovery.stop(clearUnlock: false)
        rejected = false
        do { try await recovery.enqueueRestoreDurably(cid: cid) } catch { rejected = true }
        XCTAssertTrue(rejected, "Ended account must not acknowledge enqueue")
    }
    func testNewGapRescansCompletedEpochWithoutPinOrLiveStateMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        let namespace = "test-\(UUID().uuidString)"; let user = "fixture-sender"
        let cid = "messaging:project:archive-fixture"
        let provider = Provider(); let sender = try Identity(provider: provider, userId: user)
        let group = try Group.createWithCid(provider: provider, founder: sender, cid: cid)
        let archive = try group.archiveEpochV2()
        let ciphertext = try group.createMessage(provider: provider, sender: sender, plaintext: Data("restored-on-device".utf8))
        let hash = archive.snapshotHash.map { String(format: "%02x", $0) }.joined()
        let keys = try generateRecoveryKeys(); let vault = try createRecoveryVault(pin: "12345678", keys: keys)
        let blob = try sealRecoveryArchive(archive: archive.archiveBytes, cid: cid, groupGeneration: 3, epoch: 0, scope: "account_owned", blobId: "blob", snapshotHash: hash)
        let wrap = try wrapRecoveryArchiveKey(adk: blob.adk, publicKey: keys.publicKey, cid: cid, groupGeneration: 3, epoch: 0, scope: "account_owned", blobId: "blob", snapshotHash: hash, keyId: keys.keyId)
        let applied = ArchiveApplyCounter()
        let recovery = try E2eeArchiveRecovery(namespace: namespace, root: root, userId: user, api: nil,
            isCurrentAccount: { true }, generation: { _ in 3 }, apply: { _, _, opened, snapshot, message in
                let decoded = try decryptEpochArchiveV2(provider: provider, archive: opened, snapshot: snapshot, ciphertext: message["mls_ciphertext"].bytes!, allowOwnMessages: true, maxForwardDistance: 0)
                XCTAssertEqual(String(data: decoded.content, encoding: .utf8), "restored-on-device"); applied.increment()
            }, requestOverride: { endpoint in
                switch endpoint.path {
                case .recoveryVault: return .object(["vault_bytes": .bytes(vault), "revision": .uint(1), "recovery_key_id": .string(keys.keyId)])
                case .epochArchive(_, .availability): return .object(["epochs": .array([.object(["epoch": .uint(0)])]), "has_more": .bool(false)])
                case .epochArchive(_, .material): return .object([
                    "blobs": .array([.object(["cid": .string(cid), "epoch": .uint(0), "archive_blob_id": .string("blob"), "archive_scope": .string("account_owned"), "member_snapshot_hash": .string(hash), "encrypted_archive_bytes": .bytes(blob.ciphertext), "aead_nonce": .bytes(blob.nonce), "aead_aad": .bytes(blob.aeadAad)])]),
                    "wraps": .array([.object(["archive_blob_id": .string("blob"), "recipient_user_id": .string(user), "recipient_recovery_key_id": .string(keys.keyId), "hpke_kem_output": .bytes(wrap.kemOutput), "hpke_ciphertext": .bytes(wrap.ciphertext), "hpke_info": .bytes(wrap.hpkeInfo), "ciphersuite": .uint(3)])]),
                    "snapshots": .object([hash: .object(["snapshot_bytes": .bytes(archive.snapshotBytes)])])])
                case .epochArchive(_, .ciphertexts): return .object(["ciphertexts": .array([.object(["message_id": .string("restored-message"), "cid": .string(cid), "group_generation": .uint(3), "mls_epoch": .uint(0), "mls_ciphertext": .bytes(ciphertext)])]), "has_more": .bool(false)])
                default: throw E2eeArchiveError.invalidData
                }
            })
        defer { try? recovery.stop() }
        let journal = try RecoveryJournal(path: root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
        await recovery.enqueueRestore(cid: cid, fromEpoch: 0, toEpoch: 0)
        try await waitUntil { try journal.get(key: "restore:\(cid):3")?.status == "requires_pin" }
        try await recovery.unlockRecoveryVault("12345678")
        try await waitUntil { try journal.get(key: "restore:\(cid):3")?.status == "done" }
        XCTAssertEqual(applied.count, 1)
        await recovery.enqueueRestore(cid: cid, fromEpoch: 0, toEpoch: 0)
        try await waitUntil { try journal.get(key: "restore:\(cid):3")?.status == "done" }
        XCTAssertEqual(applied.count, 2); XCTAssertEqual(group.epoch(), 0)
        let status = await recovery.currentStatus(); XCTAssertTrue(status.unlocked)
        try recovery.clearRecoveryUnlock()
        try await recovery.repairRecoveryChannel(cid: cid)
        let request = await recovery.currentStatus()
        XCTAssertEqual(request.state, "requires_pin"); XCTAssertEqual(request.pinRequestRevision, 1)
    }
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while try !condition() {
            guard Date() < deadline else { XCTFail("Recovery fixture timed out"); throw E2eeArchiveError.invalidData }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func testOfflineUploadReopensSameCryptographicRequestThenAcknowledges() async throws { try await queueScenario(.serviceUnavailable) }
    func testPermissionDeniedPausesUntilExplicitChannelRetry() async throws { try await queueScenario(.noPermission) }
    private func queueScenario(_ failure: ErmisErrorType) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        let namespace = "test-\(UUID().uuidString)"
        let cid = "messaging:project:archive-fixture"
        let keys = try generateRecoveryKeys()
        let vault = try createRecoveryVault(pin: "12345678", keys: keys)
        let fixture = ArchiveControlFixture(vault: vault, keyId: keys.keyId, failure: failure)
        func owner() throws -> E2eeArchiveRecovery {
            try E2eeArchiveRecovery(namespace: namespace, root: root, userId: "fixture-sender", api: nil,
                isCurrentAccount: { true }, generation: { _ in 3 }, apply: { _,_,_,_,_ in },
                requestOverride: { try await fixture.request($0) })
        }
        let journalPath = root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path
        var recovery = try owner()
        defer { try? recovery.stop() }
        try await recovery.unlockRecoveryVault("12345678")
        let provider = Provider(); let sender = try Identity(provider: provider, userId: "fixture-sender")
        let group = try Group.createWithCid(provider: provider, founder: sender, cid: cid)
        try recovery.capture(cid: cid, generation: 3, group: group, role: "primary")
        let journal = try RecoveryJournal(path: journalPath)
        let paused = failure == .noPermission
        let deadline = Date().addingTimeInterval(15)
        var pending: RecoveryJournalEntry?
        repeat {
            pending = try journal.page(kind: "upload", status: paused ? "permission_denied" : "queued", now: .max, cid: nil, afterKey: nil, limit: 1).first
            if let pending, paused || pending.retryCount > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        let saved = try XCTUnwrap(pending)
        try recovery.stop(clearUnlock: false)
        recovery = try owner()
        if paused {
            await recovery.resume(); try await Task.sleep(nanoseconds: 100_000_000)
            let before = await fixture.requests(); XCTAssertEqual(before.count, 1)
            let count = try await recovery.retryBlockedArchiveUploads(cid: cid); XCTAssertEqual(count, 1)
        } else { var row = saved; row.nextRetryAt = 0; try journal.put(entry: row); await recovery.resume() }
        var acknowledged = false
        repeat {
            acknowledged = try !journal.page(kind: "ack", status: "idempotent", now: .max, cid: nil, afterKey: nil, limit: 1).isEmpty
            if acknowledged { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        XCTAssertTrue(acknowledged)
        let bodies = await fixture.requests(); XCTAssertEqual(bodies.count, 2)
        guard bodies.count == 2 else { return }
        let first = try JSONEncoder().encode(bodies[0]); let last = try JSONEncoder().encode(bodies[1])
        let firstObject = try JSONSerialization.jsonObject(with: first) as! NSDictionary
        let lastObject = try JSONSerialization.jsonObject(with: last) as! NSDictionary
        XCTAssertEqual(firstObject, lastObject)
        XCTAssertNil(try journal.get(key: saved.key))
    }
}

private final class ArchiveApplyCounter {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
