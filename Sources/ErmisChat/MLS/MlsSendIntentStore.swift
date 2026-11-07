import Foundation
import SQLite3
import CryptoKit

enum MlsSendIntentError: Error { case invalid, conflict, storage, terminal, explicitRetryRequired, capacity }

struct MlsSendIntent: Codable, Equatable {
    enum Phase: String, Codable {
        case unsealed, failedUnsealed, sealed, dispatched, canceled, canceledDispatched, accepted
    }
    let version: Int
    let uuid: String
    let owner: String
    let cid: String
    let scope: String
    let groupId: Data
    let generation: UInt64
    let providerId: String
    let payload: Data
    let aad: Data
    let originalEnvelope: Data
    var phase: Phase
    var ciphertext: Data?
    var epoch: UInt64?
    var wireEnvelope: Data?
    var revision: UInt64
    var nativeSealed: Bool = false
    var nativeRetired: Bool = false
    var editMessageId: String? = nil
    var editBaseCiphertextHash: Data? = nil

    var requiresReconcile: Bool { phase == .dispatched || phase == .canceledDispatched }
    func validate() throws {
        guard (editMessageId == nil) == (editBaseCiphertextHash == nil),
              editMessageId.map({ UUID(uuidString: $0) != nil }) ?? true,
              editBaseCiphertextHash.map({ $0.count == 32 }) ?? true else { throw MlsSendIntentError.invalid }
        guard version == 1, UUID(uuidString: uuid) != nil, uuid == uuid.lowercased(),
              !owner.isEmpty, owner.utf8.count <= 512, !cid.isEmpty, cid.utf8.count <= 512,
              scope.count == 64, providerId.count == 64,
              [scope, providerId].allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
              (1...255).contains(groupId.count), !payload.isEmpty, payload.count <= 1_048_576,
              aad.count <= 65_536, originalEnvelope.count <= 4_194_304,
              (ciphertext == nil) == (epoch == nil), (ciphertext == nil) == (wireEnvelope == nil),
              !nativeSealed || ciphertext != nil,
              !nativeRetired || phase == .accepted || phase == .canceled else { throw MlsSendIntentError.invalid }
        if [.sealed, .dispatched, .canceledDispatched, .accepted].contains(phase), ciphertext?.isEmpty != false {
            throw MlsSendIntentError.invalid
        }
        if [.unsealed, .failedUnsealed].contains(phase), ciphertext != nil { throw MlsSendIntentError.invalid }
    }
}

extension MlsSendIntent {
    enum CodingKeys: String, CodingKey {
        case version, uuid, owner, cid, scope, groupId, generation, providerId, payload, aad,
             originalEnvelope, phase, ciphertext, epoch, wireEnvelope, revision, nativeSealed, nativeRetired, editMessageId, editBaseCiphertextHash
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        uuid = try c.decode(String.self, forKey: .uuid); owner = try c.decode(String.self, forKey: .owner)
        cid = try c.decode(String.self, forKey: .cid); scope = try c.decode(String.self, forKey: .scope)
        groupId = try c.decode(Data.self, forKey: .groupId); generation = try c.decode(UInt64.self, forKey: .generation)
        providerId = try c.decode(String.self, forKey: .providerId); payload = try c.decode(Data.self, forKey: .payload)
        aad = try c.decode(Data.self, forKey: .aad); originalEnvelope = try c.decode(Data.self, forKey: .originalEnvelope)
        phase = try c.decode(Phase.self, forKey: .phase); ciphertext = try c.decodeIfPresent(Data.self, forKey: .ciphertext)
        epoch = try c.decodeIfPresent(UInt64.self, forKey: .epoch); wireEnvelope = try c.decodeIfPresent(Data.self, forKey: .wireEnvelope)
        revision = try c.decode(UInt64.self, forKey: .revision)
        nativeSealed = try c.decodeIfPresent(Bool.self, forKey: .nativeSealed) ?? false
        nativeRetired = try c.decodeIfPresent(Bool.self, forKey: .nativeRetired) ?? false
        editMessageId = try c.decodeIfPresent(String.self, forKey: .editMessageId)
        editBaseCiphertextHash = try c.decodeIfPresent(Data.self, forKey: .editBaseCiphertextHash)
        try validate()
    }
}

/// Indexed UUID lookup + revision CAS. Reuses provider scope ownership; no native/HTTP operation
/// occurs under a client transaction. Native sealing owns a separate atomic ratchet+journal commit.
final class MlsSendIntentStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw MlsSendIntentError.storage
        }
        sqlite3_busy_timeout(database, 1000)
        do {
            try execute("CREATE TABLE IF NOT EXISTS ermis_send_intents_v1 (uuid TEXT PRIMARY KEY NOT NULL, owner TEXT NOT NULL, phase TEXT NOT NULL, record BLOB NOT NULL, digest BLOB NOT NULL, retirement INTEGER NOT NULL DEFAULT 0)")
            var info: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(ermis_send_intents_v1)", -1, &info, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
            var hasRetirement = false
            while sqlite3_step(info) == SQLITE_ROW {
                if let name = sqlite3_column_text(info, 1), String(cString: name) == "retirement" { hasRetirement = true }
            }
            sqlite3_finalize(info)
            if !hasRetirement {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("ALTER TABLE ermis_send_intents_v1 ADD COLUMN retirement INTEGER NOT NULL DEFAULT 0")
                    try execute("UPDATE ermis_send_intents_v1 SET retirement=1 WHERE phase IN ('accepted','canceled')")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            try execute("CREATE INDEX IF NOT EXISTS ermis_send_intents_retirement_v1 ON ermis_send_intents_v1(owner,retirement)")
            try execute("CREATE INDEX IF NOT EXISTS ermis_send_intents_phase_v1 ON ermis_send_intents_v1(owner,phase)")
            var columns: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(ermis_send_intents_v1)", -1, &columns, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
            var names = Set<String>()
            while sqlite3_step(columns) == SQLITE_ROW {
                if let name = sqlite3_column_text(columns, 1) { names.insert(String(cString: name)) }
            }
            sqlite3_finalize(columns)
            if !names.contains("edit_message_id") || !names.contains("cipher_sha256") {
                try execute("BEGIN IMMEDIATE")
                do {
                    if !names.contains("edit_message_id") { try execute("ALTER TABLE ermis_send_intents_v1 ADD COLUMN edit_message_id TEXT") }
                    if !names.contains("cipher_sha256") { try execute("ALTER TABLE ermis_send_intents_v1 ADD COLUMN cipher_sha256 BLOB") }
                    var rows: OpaquePointer?
                    guard sqlite3_prepare_v2(database, "SELECT uuid FROM ermis_send_intents_v1", -1, &rows, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
                    defer { sqlite3_finalize(rows) }
                    var step = sqlite3_step(rows)
                    while step == SQLITE_ROW {
                        guard let key = sqlite3_column_text(rows, 0), let record = try read(String(cString: key)) else { throw MlsSendIntentError.storage }
                        try writeEditIndex(record)
                        step = sqlite3_step(rows)
                    }
                    guard step == SQLITE_DONE else { throw MlsSendIntentError.storage }
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            try execute("CREATE INDEX IF NOT EXISTS ermis_caption_edit_cipher_v1 ON ermis_send_intents_v1(owner,edit_message_id,cipher_sha256,phase)")

        }
        catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
    }
    private func read(_ uuid: String) throws -> MlsSendIntent? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT record,digest,owner,phase FROM ermis_send_intents_v1 WHERE uuid=?", -1, &statement, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, uuid, -1, transient) == SQLITE_OK else { throw MlsSendIntentError.storage }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, (1...8_388_608).contains(Int(sqlite3_column_bytes(statement, 0))),
              let bytes = sqlite3_column_blob(statement, 0), let hash = sqlite3_column_blob(statement, 1),
              sqlite3_column_bytes(statement, 1) == 32, let owner = sqlite3_column_text(statement, 2),
              let phase = sqlite3_column_text(statement, 3) else { throw MlsSendIntentError.storage }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard Data(SHA256.hash(data: data)) == Data(bytes: hash, count: 32) else { throw MlsSendIntentError.storage }
        let record = try JSONDecoder().decode(MlsSendIntent.self, from: data)
        try record.validate()
        guard record.uuid == uuid, record.owner == String(cString: owner), record.phase.rawValue == String(cString: phase) else { throw MlsSendIntentError.conflict }
        return record
    }
    private func writeEditIndex(_ record: MlsSendIntent) throws {
        guard let id = record.editMessageId, let cipher = record.ciphertext else { return }
        let hash = Data(SHA256.hash(data: cipher))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE ermis_send_intents_v1 SET edit_message_id=?,cipher_sha256=? WHERE uuid=?", -1, &statement, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
        defer { sqlite3_finalize(statement) }
        let result = hash.withUnsafeBytes { b in
            sqlite3_bind_text(statement, 1, id.lowercased(), -1, transient) == SQLITE_OK &&
            sqlite3_bind_blob(statement, 2, b.baseAddress, Int32(b.count), transient) == SQLITE_OK &&
            sqlite3_bind_text(statement, 3, record.uuid, -1, transient) == SQLITE_OK && sqlite3_step(statement) == SQLITE_DONE
        }
        guard result else { throw MlsSendIntentError.storage }
    }

    /// Replays a past own-device edit from its accepted durable intent; never MLS-decrypts self.
    func acceptedEdit(owner: String, messageId: String, ciphertext: Data) throws -> MlsSendIntent? {
        lock.lock(); defer { lock.unlock() }
        let hash = Data(SHA256.hash(data: ciphertext))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT uuid FROM ermis_send_intents_v1 WHERE owner=? AND edit_message_id=? AND cipher_sha256=? AND phase='accepted' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
        defer { sqlite3_finalize(statement) }
        let bound = hash.withUnsafeBytes { b in
            sqlite3_bind_text(statement, 1, owner, -1, transient) == SQLITE_OK &&
            sqlite3_bind_text(statement, 2, messageId.lowercased(), -1, transient) == SQLITE_OK &&
            sqlite3_bind_blob(statement, 3, b.baseAddress, Int32(b.count), transient) == SQLITE_OK
        }
        guard bound else { throw MlsSendIntentError.storage }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let id = sqlite3_column_text(statement, 0), let record = try read(String(cString: id)),
              record.owner == owner, record.editMessageId?.lowercased() == messageId.lowercased(),
              record.ciphertext == ciphertext, record.phase == .accepted else { throw MlsSendIntentError.storage }
        return record
    }

    func load(uuid: String, owner: String) throws -> MlsSendIntent? {
        lock.lock(); defer { lock.unlock() }
        let record = try read(uuid)
        if let record, record.owner != owner { throw MlsSendIntentError.conflict }
        return record
    }
    func pendingReconciliations(owner: String, limit: Int = 4) throws -> [MlsSendIntent] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard (1...4).contains(limit), sqlite3_prepare_v2(database,
            "SELECT uuid FROM ermis_send_intents_v1 WHERE owner=? AND phase IN ('dispatched','canceledDispatched') ORDER BY rowid LIMIT ?",
            -1, &statement, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, owner, -1, transient) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else { throw MlsSendIntentError.storage }
        var records: [MlsSendIntent] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let bytes = sqlite3_column_text(statement, 0), let record = try read(String(cString: bytes)),
                  record.owner == owner, record.requiresReconcile else { throw MlsSendIntentError.conflict }
            records.append(record); result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw MlsSendIntentError.storage }
        return records
    }

    func pendingRetirements(owner: String, limit: Int = 32) throws -> [MlsSendIntent] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard (1...32).contains(limit), sqlite3_prepare_v2(database,
            "SELECT uuid FROM ermis_send_intents_v1 WHERE owner=? AND retirement=1 ORDER BY rowid LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, owner, -1, transient) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else { throw MlsSendIntentError.storage }
        var rows: [MlsSendIntent] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let bytes = sqlite3_column_text(statement, 0), let record = try read(String(cString: bytes)),
                  record.owner == owner, !record.nativeRetired, [.accepted, .canceled].contains(record.phase) else { throw MlsSendIntentError.conflict }
            rows.append(record)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw MlsSendIntentError.storage }
        return rows
    }

    @discardableResult
    func save(_ next: MlsSendIntent, replacing expected: MlsSendIntent?, assertCurrent: () throws -> Void) throws -> MlsSendIntent {
        try next.validate()
        lock.lock(); defer { lock.unlock() }
        try assertCurrent()
        try execute("BEGIN IMMEDIATE")
        do {
            let stored = try read(next.uuid)
            guard stored == expected else { throw MlsSendIntentError.conflict }
            if let previous = expected {
                guard previous.owner == next.owner, previous.cid == next.cid, previous.scope == next.scope,
                      previous.groupId == next.groupId, previous.generation == next.generation,
                      previous.providerId == next.providerId, previous.payload == next.payload,
                      previous.aad == next.aad, previous.originalEnvelope == next.originalEnvelope,
                      previous.editMessageId == next.editMessageId, previous.editBaseCiphertextHash == next.editBaseCiphertextHash,
                      previous.revision < UInt64.max, next.revision == previous.revision + 1 else { throw MlsSendIntentError.conflict }
                if let cipher = previous.ciphertext {
                    guard next.ciphertext == cipher, next.epoch == previous.epoch, next.wireEnvelope == previous.wireEnvelope else { throw MlsSendIntentError.conflict }
                }
                let allowed: [MlsSendIntent.Phase: Set<MlsSendIntent.Phase>] = [
                    .unsealed: [.sealed, .failedUnsealed, .canceled], .failedUnsealed: [.unsealed, .canceled],
                    .sealed: [.dispatched, .canceled], .dispatched: [.accepted, .canceledDispatched],
                    .canceledDispatched: [.accepted], .accepted: [], .canceled: []]
                let finishingRetirement = previous.phase == next.phase && [.accepted, .canceled].contains(next.phase)
                    && !previous.nativeRetired && next.nativeRetired
                guard allowed[previous.phase]?.contains(next.phase) == true || finishingRetirement else { throw MlsSendIntentError.terminal }
                let recoveredCancellation = [.unsealed, .failedUnsealed].contains(previous.phase)
                    && next.phase == .canceled && previous.ciphertext == nil
                    && next.nativeSealed && next.ciphertext != nil && next.wireEnvelope != nil
                guard !next.nativeRetired || previous.nativeRetired || finishingRetirement,
                      !previous.nativeSealed || next.nativeSealed,
                      !previous.nativeRetired || next.nativeRetired,
                      previous.nativeSealed == next.nativeSealed || (previous.phase == .unsealed && next.phase == .sealed) || recoveredCancellation else { throw MlsSendIntentError.conflict }
            } else {
                guard next.phase == .unsealed, next.revision == 0 else { throw MlsSendIntentError.invalid }
                var budget: OpaquePointer?
                guard sqlite3_prepare_v2(database, "SELECT count(*),coalesce(sum(length(record)),0) FROM ermis_send_intents_v1 WHERE phase NOT IN ('accepted','canceled')", -1, &budget, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
                defer { sqlite3_finalize(budget) }
                guard sqlite3_step(budget) == SQLITE_ROW, sqlite3_column_int64(budget, 0) < 256,
                      sqlite3_column_int64(budget, 1) + Int64(next.payload.count + next.originalEnvelope.count + 2_097_152) <= 67_108_864 else { throw MlsSendIntentError.capacity }
            }
            let data = try JSONEncoder().encode(next)
            let hash = Data(SHA256.hash(data: data))
            guard data.count <= 8_388_608 else { throw MlsSendIntentError.capacity }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO ermis_send_intents_v1(uuid,owner,phase,record,digest,retirement) VALUES(?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw MlsSendIntentError.storage }
            defer { sqlite3_finalize(statement) }
            let result = data.withUnsafeBytes { bytes in hash.withUnsafeBytes { digest in
                sqlite3_bind_text(statement, 1, next.uuid, -1, transient) == SQLITE_OK &&
                sqlite3_bind_text(statement, 2, next.owner, -1, transient) == SQLITE_OK &&
                sqlite3_bind_text(statement, 3, next.phase.rawValue, -1, transient) == SQLITE_OK &&
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bytes.count), transient) == SQLITE_OK &&
                sqlite3_bind_blob(statement, 5, digest.baseAddress, Int32(digest.count), transient) == SQLITE_OK &&
                sqlite3_bind_int(statement, 6, ([MlsSendIntent.Phase.accepted, .canceled].contains(next.phase) && !next.nativeRetired) ? 1 : 0) == SQLITE_OK &&
                sqlite3_step(statement) == SQLITE_DONE
            } }
            guard result, try read(next.uuid) == next else { throw MlsSendIntentError.storage }
            try writeEditIndex(next)
            try assertCurrent()
            try execute("COMMIT")
            return next
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
