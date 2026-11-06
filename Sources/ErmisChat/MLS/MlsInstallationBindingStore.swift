import Foundation
import SQLite3

/// Public binding stored inside the private provider database. This table does
/// not change the native provider's user_version or any of its schema objects.
struct MlsInstallationBinding: Equatable {
    let userId: String
    let deviceId: String
    let signerSha256: String
}

final class MlsInstallationBindingStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ClientError.Unexpected("mls_binding_storage_unavailable")
        }
        sqlite3_busy_timeout(database, 1000)
        do {
            try execute("CREATE TABLE IF NOT EXISTS ermis_installation_binding_v1 (slot INTEGER PRIMARY KEY CHECK(slot=1),user_id TEXT NOT NULL,device_id TEXT NOT NULL,signer_sha256 TEXT NOT NULL)")
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }
    deinit { sqlite3_close(database) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClientError.Unexpected("mls_binding_storage_failed")
        }
    }

    func load() throws -> MlsInstallationBinding? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT user_id,device_id,signer_sha256 FROM ermis_installation_binding_v1 WHERE slot=1", -1, &statement, nil) == SQLITE_OK else {
            throw ClientError.Unexpected("mls_binding_storage_failed")
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let user = sqlite3_column_text(statement, 0),
              let device = sqlite3_column_text(statement, 1),
              let signer = sqlite3_column_text(statement, 2) else {
            throw ClientError.Unexpected("mls_binding_storage_failed")
        }
        return MlsInstallationBinding(userId: String(cString: user), deviceId: String(cString: device), signerSha256: String(cString: signer))
    }

    /// Insert-only and read back: a competing setup can select the same binding,
    /// but cannot replace an already published device identity.
    func reserve(_ binding: MlsInstallationBinding) throws -> MlsInstallationBinding {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO ermis_installation_binding_v1(slot,user_id,device_id,signer_sha256) VALUES(1,?,?,?)", -1, &statement, nil) == SQLITE_OK else {
            throw ClientError.Unexpected("mls_binding_storage_failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, binding.userId, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, binding.deviceId, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, binding.signerSha256, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              let stored = try load() else {
            throw ClientError.Unexpected("mls_binding_storage_failed")
        }
        return stored
    }
}
