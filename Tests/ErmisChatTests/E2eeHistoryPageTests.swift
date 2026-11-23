import Foundation
import CryptoKit
import XCTest
import open_mls_ios
@testable import ErmisChat

private actor PageMaterialRequests {
    let vault: E2eeArchiveWire
    let material: [UInt64: E2eeArchiveWire]
    var reads = 0
    var unexpected = 0
    init(vault: E2eeArchiveWire, material: [UInt64: E2eeArchiveWire]) { self.vault = vault; self.material = material }
    func request(_ endpoint: Endpoint<E2eeArchiveWire>) throws -> E2eeArchiveWire {
        switch endpoint.path {
        case .recoveryVault: return vault
        case .epochArchive(_, .material):
            guard let body = endpoint.body as? E2eeArchiveWire, let gen = body["group_generation"].number,
                  let result = material[gen] else { throw E2eeArchiveError.invalidData }
            reads += 1; return result
        default: unexpected += 1; throw E2eeArchiveError.invalidData
        }
    }
    func counts() -> (Int, Int) { (reads, unexpected) }
}

final class E2eeHistoryPageTests: XCTestCase {
    func testBaselineOmittedGenerationIsZeroAndExplicitInvalidProvenanceStaysRejected() throws {
        let base: [String: Any] = ["id": UUID().uuidString.lowercased(), "cid": "messaging:project:page",
            "user": ["id": "sender"], "created_at": "2026-11-17T00:00:00.000Z",
            "content_type": "mls", "mls_ciphertext": [1, 2, 3], "mls_epoch": 7]
        let legacy = try JSONDecoder.default.decode(MessagePayload.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertTrue(legacy.hasAuthoritativeGroupGeneration)
        XCTAssertEqual(legacy.groupGeneration, 0)
        for generation in [0, 4] {
            var wire = base; wire["group_generation"] = generation
            let decoded = try JSONDecoder.default.decode(MessagePayload.self, from: JSONSerialization.data(withJSONObject: wire))
            XCTAssertTrue(decoded.hasAuthoritativeGroupGeneration); XCTAssertEqual(decoded.groupGeneration, generation)
        }
        var invalid = base; invalid["group_generation"] = NSNull()
        let null = try JSONDecoder.default.decode(MessagePayload.self, from: JSONSerialization.data(withJSONObject: invalid))
        XCTAssertFalse(null.hasAuthoritativeGroupGeneration)
        invalid["group_generation"] = "bad"
        XCTAssertThrowsError(try JSONDecoder.default.decode(MessagePayload.self, from: JSONSerialization.data(withJSONObject: invalid)))
    }

    func testExactPageMixedGenerationsUsesOnlyMaterialAndIndependentProvider() async throws {
        let account = "page-" + UUID().uuidString, cid = "messaging:project:page"
        let keys = try generateRecoveryKeys(), vaultBytes = try createRecoveryVault(pin: "12345678", keys: keys)
        var material: [UInt64: E2eeArchiveWire] = [:], page: [E2eeArchiveWire] = [], expected: [String: Data] = [:]
        for gen: UInt64 in [0, 4] {
            let provider = Provider(), sender = try Identity(provider: provider, userId: "sender")
            let group = try Group.createWithCid(provider: provider, founder: sender, cid: cid)
            let exported = try group.archiveEpochV2()
            let hash = Data(SHA256.hash(data: exported.snapshotBytes)).map { String(format: "%02x", $0) }.joined()
            let blobId = UUID().uuidString.lowercased()
            let blob = try sealRecoveryArchive(archive: exported.archiveBytes, cid: cid, groupGeneration: gen,
                epoch: group.epoch(), scope: "account_owned", blobId: blobId, snapshotHash: hash)
            let wrap = try wrapRecoveryArchiveKey(adk: blob.adk, publicKey: keys.publicKey, cid: cid, groupGeneration: gen,
                epoch: group.epoch(), scope: "account_owned", blobId: blobId, snapshotHash: hash, keyId: keys.keyId)
            material[gen] = .object([
                "blobs": .array([.object(["archive_blob_id": .string(blobId), "cid": .string(cid), "epoch": .uint(0),
                    "archive_scope": .string("account_owned"), "member_snapshot_hash": .string(hash),
                    "encrypted_archive_bytes": .bytes(blob.ciphertext), "aead_nonce": .bytes(blob.nonce), "aead_aad": .bytes(blob.aeadAad)])]),
                "wraps": .array([.object(["archive_blob_id": .string(blobId), "recipient_user_id": .string(account),
                    "recipient_recovery_key_id": .string(keys.keyId), "hpke_kem_output": .bytes(wrap.kemOutput),
                    "hpke_ciphertext": .bytes(wrap.ciphertext), "hpke_info": .bytes(wrap.hpkeInfo), "ciphersuite": .uint(3)])]),
                "snapshots": .object([hash: .object(["snapshot_hash": .string(hash), "cid": .string(cid), "snapshot_bytes": .bytes(exported.snapshotBytes)])])])
            for n in 0..<25 {
                let id = UUID().uuidString.lowercased(), text = Data("page-\(gen)-\(n)".utf8)
                expected[id] = text
                let cipher = try group.createMessage(provider: provider, sender: sender, plaintext: text)
                page.append(.object(["message_id": .string(id), "cid": .string(cid), "e2ee_group_id": .string(cid),
                    "group_generation": .uint(gen), "mls_epoch": .uint(0), "mls_ciphertext": .bytes(cipher),
                    "created_at": .string("2026-11-17T00:00:00Z"), "user_id": .string("sender")]))
            }
            XCTAssertEqual(group.epoch(), 0)
        }
        let fixture = PageMaterialRequests(vault: .object(["vault_bytes": .bytes(vaultBytes), "revision": .uint(1), "recovery_key_id": .string(keys.keyId)]), material: material)
        var seen = Set<String>()
        let recovery = try E2eeArchiveRecovery(namespace: "test-" + UUID().uuidString,
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), userId: account, api: nil,
            isCurrentAccount: { true }, generation: { _ in 99 }, apply: { _, _, _, _, _ in XCTFail("Legacy/live apply must not run") },
            requestOverride: { try await fixture.request($0) }, applyPage: { _, gen, archive, snapshot, message in
                XCTAssertEqual(gen, message["group_generation"].number)
                let decoded = try decryptEpochArchiveV2(provider: Provider(), archive: archive, snapshot: snapshot,
                    ciphertext: try XCTUnwrap(message["mls_ciphertext"].bytes), allowOwnMessages: true, maxForwardDistance: 0)
                let id = try XCTUnwrap(message["message_id"].string)
                XCTAssertEqual(decoded.content, expected[id]); seen.insert(id)
            })
        defer { try? recovery.stop(clearUnlock: true) }
        try await recovery.unlockRecoveryVault("12345678")
        let first = try await recovery.restoreHistoryPage(cid: cid, messages: page)
        XCTAssertEqual(first.restored, 50); XCTAssertEqual(first.unavailable, 0)
        XCTAssertEqual(seen, Set(expected.keys))
        _ = try await recovery.restoreHistoryPage(cid: cid, messages: Array(page.prefix(1)))
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
        do { _ = try await recovery.restoreHistoryPage(cid: cid, messages: page + [page[0]]); XCTFail("Oversized page accepted") }
        catch E2eeArchiveError.invalidData { }
        let status = try await recovery.getRecoveryStatus()
        XCTAssertEqual(status.state, "page_ready"); XCTAssertNotEqual(status.historyState, "done")
    }
    func testRequestedPageDistinguishesMissingArchiveWrapSnapshotAndTransportFailure() async throws {
        for reason in ["no_accessible_archive", "matching_wrap_unavailable", "snapshot_unavailable", "material_network_error"] {
            let account = "reason-" + UUID().uuidString, cid = "messaging:project:reason", id = UUID().uuidString.lowercased()
            let keys = try generateRecoveryKeys(), bytes = try createRecoveryVault(pin: "12345678", keys: keys)
            let vault: E2eeArchiveWire = .object(["vault_bytes": .bytes(bytes), "revision": .uint(1), "recovery_key_id": .string(keys.keyId)])
            let recovery = try E2eeArchiveRecovery(namespace: "test-" + UUID().uuidString,
                root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), userId: account, api: nil,
                isCurrentAccount: { true }, generation: { _ in 9 }, apply: { _, _, _, _, _ in XCTFail("Must not touch live provider") },
                requestOverride: { endpoint in
                    if case .recoveryVault = endpoint.path { return vault }
                    if reason == "material_network_error" { throw URLError(.notConnectedToInternet) }
                    let blob: E2eeArchiveWire = .object(["cid": .string(cid), "epoch": .uint(0), "archive_blob_id": .string("blob"), "member_snapshot_hash": .string("hash")])
                    let wrap: E2eeArchiveWire = .object(["archive_blob_id": .string("blob"), "recipient_user_id": .string(account), "recipient_recovery_key_id": .string(keys.keyId)])
                    return .object(["blobs": .array(reason == "no_accessible_archive" ? [] : [blob]),
                        "wraps": .array(reason == "snapshot_unavailable" ? [wrap] : []), "snapshots": .object([:])])
                }, applyPage: { _, _, _, _, _ in XCTFail("Unavailable material must not apply") })
            defer { try? recovery.stop(clearUnlock: true) }
            try await recovery.unlockRecoveryVault("12345678")
            let result = try await recovery.restoreHistoryPage(cid: cid, messages: [.object(["message_id": .string(id), "cid": .string(cid),
                "group_generation": .uint(0), "mls_epoch": .uint(0), "mls_ciphertext": .bytes(Data([1, 2]))])])
            XCTAssertEqual(result.restored, 0); XCTAssertEqual(result.unavailable, 1)
            XCTAssertEqual(result.failures[id], [reason])
        }
    }

}
