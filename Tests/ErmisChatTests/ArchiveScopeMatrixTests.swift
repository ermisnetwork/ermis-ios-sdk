import Foundation
import XCTest
import open_mls_ios
@testable import ErmisChat

final class ArchiveScopeMatrixTests: XCTestCase {
    private func id(_ gen: UInt64, _ epoch: UInt64, _ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012llu", gen*1_000_000+epoch*1000+UInt64(n))
    }
    func testTopicsSparseSpansAndGenerationsKeepExactIdsAndOpaqueScope() async throws {
        let cid = "messaging:project:matrix"; let topic = "messaging:project:topic"
        let keys = try generateRecoveryKeys(); let vault = try createRecoveryVault(pin: "12345678", keys: keys)
        var calls = 0; var responseBytes = 0
        for (gen, from, to) in [(UInt64(3), UInt64(2), UInt64(2)), (3, 900, 900), (4, 2, 900)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("apin-matrix-\(UUID().uuidString)")
            let namespace = "matrix-\(UUID().uuidString)"
            let recovery = try E2eeArchiveRecovery(namespace: namespace, root: root, userId: "fixture", api: nil,
                isCurrentAccount: { true }, generation: { _ in gen }, apply: { _, _, _, _, _ in XCTFail("No crypto without material") },
                requestOverride: { endpoint in
                    switch endpoint.path {
                    case .recoveryVault: return .object(["vault_bytes": .bytes(vault), "revision": .uint(1), "recovery_key_id": .string(keys.keyId)])
                    case .epochArchive(_, .availability): return .object(["epochs": .array([]), "has_more": .bool(false)])
                    case .epochArchive(_, .material): return .object(["blobs": .array([]), "wraps": .array([]), "snapshots": .object([:])])
                    case .epochArchive(let scope, .ciphertexts):
                        XCTAssertEqual(scope.rawValue, cid)
                        let query = try XCTUnwrap(endpoint.body as? E2eeArchiveWire)
                        XCTAssertEqual(query["limit"].number, 100); XCTAssertEqual(query["group_generation"].number, gen)
                        let lower = try XCTUnwrap(query["epoch_from"].number); let upper = try XCTUnwrap(query["epoch_to"].number)
                        let prefix = "opaque+/=matrix:\(gen):\(lower):\(upper):"
                        let cursor = query["cursor"]["last_event_key"].string
                        let offset = cursor.flatMap { Int($0.split(separator: ":").last ?? "") } ?? 0
                        if let cursor { XCTAssertEqual(cursor, prefix+String(offset)) }
                        let all: [E2eeArchiveWire] = [UInt64(2), 900].filter { $0 >= lower && $0 <= upper }.flatMap { epoch in
                            (0..<(epoch == 2 ? 620 : 115)).map { n in .object(["message_id": .string(self.id(gen, epoch, n)),
                                "cid": .string(n % 2 == 0 ? cid : topic), "parent_cid": .string(cid), "e2ee_group_id": .string(cid),
                                "group_generation": .uint(gen), "mls_epoch": .uint(epoch), "mls_ciphertext": .bytes(Data([1]))]) }
                        }
                        let fresh = Array(all.dropFirst(offset).prefix(offset == 0 ? 100 : 99))
                        let selected = (offset > 0 ? [all[offset-1]] : []) + fresh
                        let next = offset+fresh.count; let more = next < all.count
                        let result: E2eeArchiveWire = .object(["ciphertexts": .array(selected), "has_more": .bool(more),
                            "next_cursor": more ? .object(["last_event_key": .string(prefix+String(next))]) : .null])
                        calls += 1; responseBytes += try JSONEncoder().encode(result).count
                        return result
                    default: throw E2eeArchiveError.invalidData
                    }
                })
            defer { try? recovery.stop(clearUnlock: false) }
            try await recovery.unlockRecoveryVault("12345678")
            try await recovery.enqueueRestoreDurably(cid: cid, fromEpoch: from, toEpoch: to, requestId: "fixture-span")
            let journal = try RecoveryJournal(path: root.appendingPathComponent("MLSArchive/\(namespace)/journal.db").path)
            let deadline = Date().addingTimeInterval(15)
            while try journal.get(key: "restore:\(cid):\(gen)")?.status != "done_with_gaps" {
                guard Date() < deadline else { XCTFail("Matrix scope timed out"); return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            for epoch in [UInt64(2), 900].filter({ $0 >= from && $0 <= to }) {
                let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(journal.get(key: "restore_epoch:\(cid):\(gen):\(epoch)")?.payload)) as? [String: Any])
                let outcomes = try XCTUnwrap(proof["outcomes"] as? [String: String])
                let count = epoch == 2 ? 620 : 115
                XCTAssertEqual(Set(outcomes.keys), Set((0..<count).map { self.id(gen, epoch, $0) }))
                XCTAssertEqual(proof["discovered"] as? Int, count)
                XCTAssertTrue(outcomes.values.allSatisfy { $0 == "material_unavailable" })
            }
        }
        XCTAssertEqual(calls, 35)
        print("ARCHIVE_SCOPE_COST ciphertext_calls=\(calls) encoded_response_bytes=\(responseBytes) unique_outcomes=1470 max_page_rows=100")
    }
    func testNativeCheckpointWriteCostUsesBoundedCumulativeProofs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apin-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = try RecoveryJournal(path: root.appendingPathComponent("journal.db").path)
        var outcomes = [String: String](); var encode = [Double](); var writes = [Double](); var totalBytes = 0; var finalBytes = 0
        for page in 1...50 {
            for n in (page-1)*100..<page*100 { outcomes[id(3, 0, n)] = "material_unavailable" }
            let start = CFAbsoluteTimeGetCurrent()
            let payload = try JSONSerialization.data(withJSONObject: ["cycle": "fixture-cycle", "validatorVersion": 2, "coverageVersion": 1,
                "discovered": outcomes.count, "outcomes": outcomes, "reasons": ["material_unavailable": outcomes.count]])
            encode.append((CFAbsoluteTimeGetCurrent()-start)*1000); totalBytes += payload.count; finalBytes = payload.count
            let writeStart = CFAbsoluteTimeGetCurrent()
            try journal.put(entry: RecoveryJournalEntry(key: "restore_epoch:messaging:checkpoint-fixture:3:0", kind: "restore_epoch", cid: "messaging:checkpoint-fixture",
                groupGeneration: 3, epoch: 0, scope: "", payload: payload, status: "restoring", retryCount: 0, createdAt: 1, nextRetryAt: 0, lastError: nil))
            writes.append((CFAbsoluteTimeGetCurrent()-writeStart)*1000)
        }
        let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(journal.get(key: "restore_epoch:messaging:checkpoint-fixture:3:0")?.payload)) as? [String: Any])
        XCTAssertEqual((proof["outcomes"] as? [String: String])?.count, 5000)
        encode.sort(); writes.sort()
        print("ARCHIVE_CHECKPOINT_COST samples=50 distinct_ids=5000 total_checkpoint_payload_bytes=\(totalBytes) final_checkpoint_payload_bytes=\(finalBytes) encode_p95_ms=\(encode[47]) encode_p99_ms=\(encode[49]) write_p95_ms=\(writes[47]) write_p99_ms=\(writes[49]) write_total_ms=\(writes.reduce(0,+))")
    }
}
