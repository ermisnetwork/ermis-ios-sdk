import CryptoKit
import Foundation
import open_mls_ios

/// Fixed metadata only. No plaintext, ciphertext, credentials or error descriptions.
public enum MlsIncomingTrace {
    static func recordDuplicate(uuid: String, stored: Data, incoming: Data) {
        guard UUID(uuidString: uuid) != nil,
              let prior = try? JSONDecoder().decode(RawJSON.self, from: stored),
              let next = try? JSONDecoder().decode(RawJSON.self, from: incoming) else { return }
        // Field names only; never values or arbitrary user-defined dictionary keys.
        let allowed: Set<String> = ["type", "cid", "parent_cid", "event_id", "created_at", "data", "id", "user", "user_id", "updated_at", "last_active", "online", "name", "avatar", "image", "role", "device_id", "mls_epoch", "mls_ciphertext", "group_generation", "group_id", "group_info", "commit", "welcome", "ratchet_tree", "protocol_data", "acceptance_context", "epoch", "event_type", "msg_seq", "last_event_seq", "content_type", "text", "e2ee_group_id", "mentioned_all", "sender", "message", "members", "extra_data"]
        var paths: [String] = []
        func compare(_ left: RawJSON?, _ right: RawJSON?, path: String, depth: Int) {
            guard left != right, paths.count < 8 else { return }
            if depth < 5, case .dictionary(let a) = left, case .dictionary(let b) = right {
                for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
                    let safe = allowed.contains(key) ? key : "redacted_field"
                    compare(a[key], b[key], path: path.isEmpty ? safe : path + "." + safe, depth: depth + 1)
                }
            } else { paths.append(path.isEmpty ? "root" : path) }
        }
        compare(prior, next, path: "", depth: 0)
        let fields = String((paths.isEmpty ? ["encoding_only"] : paths).joined(separator: "|").prefix(160))
        log.info("mls_incoming_duplicate uuid=\(uuid.lowercased()) same_semantics=\(prior == next) changed=\(fields)", subsystems: .mls)
        if case .dictionary(let a) = prior, case .dictionary(let b) = next,
           let before = a["created_at"]?.stringValue, let after = b["created_at"]?.stringValue,
           [before, after].allSatisfy({ $0.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9TZ:.+-]{8,29}$", options: .regularExpression) != nil }) {
            log.info("mls_incoming_timestamp uuid=\(uuid.lowercased()) stored_at=\(before) incoming_at=\(after)", subsystems: .mls)
        }
    }
    public enum Stage: String {
        case decryptStarted = "decrypt_started"
        case decryptSucceeded = "decrypt_succeeded"
        case decryptFailed = "decrypt_failed"
        case decodedCacheSaved = "decoded_cache_saved"
        case uiRendered = "ui_rendered"
        case uiEncrypted = "ui_encrypted"
        case scopeBlocked = "scope_blocked"
        case scopePageFailed = "scope_page_failed"
        case captionCheckpointMissing = "caption_checkpoint_missing"
        case captionCheckpointRestored = "caption_checkpoint_restored"
    }
    static func errorClass(_ error: Error?) -> String {
        guard let error else { return "none" }
        switch error {
        case MlsError.MessageAlreadyConsumed: return "already_consumed"
        case MlsError.GroupNotFound: return "group_missing"
        case MlsError.GroupNotOperational: return "group_not_operational"
        case MlsError.KeyPackageExpired: return "expired"
        case MlsError.EpochConflict: return "epoch_conflict"
        case MlsError.StorageError, MlsError.StorageCorruption: return "storage"
        case MlsError.InvalidMessage, MlsError.CryptoError: return "crypto"
        case MlsError.AcceptanceMetadataInvalid: return "acceptance_metadata"
        case is DecodingError: return "payload_decode"
        case E2eeDurableInboxError.duplicateEventPayloadMismatch: return "duplicate_payload"
        case E2eeDurableInboxError.invalidPagination: return "invalid_pagination"
        case E2eeDurableInboxError.backlogLimitExceeded: return "backlog_limit"
        case is E2eeDurableInboxError: return "inbox_contract"
        default: return "other"
        }
    }
    public static func record(_ stage: Stage, uuid: String, ciphertext: Data?, error: Error? = nil) {
        guard UUID(uuidString: uuid) != nil else { return }
        let digest = ciphertext.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "absent"
        log.info("mls_incoming stage=\(stage.rawValue) uuid=\(uuid.lowercased()) cipher_sha256=\(digest) error=\(errorClass(error))", subsystems: .mls)
    }
}
