import Foundation
import CryptoKit
import SQLite3

/// Point reads and one short SQLite transaction per authoritative observation. There is no
/// network/native operation under this lock, and different processes share SQLite's CAS boundary.
final class MlsRecoveryControlStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ClientError.Unexpected("mls_control_storage_unavailable")
        }
        sqlite3_busy_timeout(database, 1000)
        do {
            try execute("CREATE TABLE IF NOT EXISTS recovery_controls_v1 (scope TEXT PRIMARY KEY NOT NULL, checkpoint TEXT NOT NULL)")
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClientError.Unexpected("mls_control_storage_failed")
        }
    }

    private func scope(userId: String, deviceId: String, signerSha256: String, cid: String) throws -> String {
        let data = try JSONEncoder().encode([userId, deviceId, signerSha256, cid])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read(scope: String) throws -> MlsRecoveryControlCheckpoint? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT checkpoint FROM recovery_controls_v1 WHERE scope=?", -1, &statement, nil) == SQLITE_OK else {
            throw ClientError.Unexpected("mls_control_storage_failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, scope, -1, transient) == SQLITE_OK else {
            throw ClientError.Unexpected("mls_control_storage_failed")
        }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard sqlite3_column_bytes(statement, 0) <= 8192,
                  let text = sqlite3_column_text(statement, 0) else {
                throw ClientError.Unexpected("mls_control_storage_failed")
            }
            let record = try JSONDecoder().decode(MlsRecoveryControlCheckpoint.self,
                                                  from: Data(String(cString: text).utf8))
            try record.validate()
            guard try self.scope(userId: record.userId, deviceId: record.deviceId,
                                 signerSha256: record.signerSha256, cid: record.cid) == scope else {
                throw ClientError.Unexpected("mls_control_owner_mismatch")
            }
            return record
        default: throw ClientError.Unexpected("mls_control_storage_failed")
        }
    }

    func load(userId: String, deviceId: String, signerSha256: String, cid: String) throws -> MlsRecoveryControlCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        return try read(scope: scope(userId: userId, deviceId: deviceId, signerSha256: signerSha256, cid: cid))
    }

    func observe(_ next: MlsRecoveryControlCheckpoint, assertCurrent: () throws -> Void) throws -> MlsRecoveryControlCheckpoint {
        try next.validate()
        lock.lock()
        defer { lock.unlock() }
        try assertCurrent()
        try execute("BEGIN IMMEDIATE")
        do {
            let key = try scope(userId: next.userId, deviceId: next.deviceId, signerSha256: next.signerSha256, cid: next.cid)
            let selected = try next.selected(after: read(scope: key))
            let data = try JSONEncoder().encode(selected)
            guard data.count <= 8192, let json = String(data: data, encoding: .utf8) else {
                throw MlsRecoveryControlError.invalidMetadata
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO recovery_controls_v1(scope,checkpoint) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else {
                throw ClientError.Unexpected("mls_control_storage_failed")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, json, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE,
                  try read(scope: key) == selected else {
                throw ClientError.Unexpected("mls_control_storage_failed")
            }
            try assertCurrent()
            try execute("COMMIT")
            return selected
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
