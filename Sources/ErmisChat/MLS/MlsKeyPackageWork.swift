import Foundation
import CryptoKit
import open_mls_ios

struct MlsKeyPackageUploadRejection: Error { let batchId: String }
struct MlsKeyPackageBatchInvalid: Error {}

struct MlsOwnershipCursor: Codable, Equatable { let id: String; let created_at: String }
struct MlsOwnershipEntry: Decodable {
    let id: String; let created_at: String; let key_package_ref: Data
    enum CodingKeys: String, CodingKey { case id, created_at, key_package_ref }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); created_at = try c.decode(String.self, forKey: .created_at)
        key_package_ref = Data(try c.decodeE2eeBytes(forKey: .key_package_ref))
    }
}
struct MlsOwnershipInventory: Decodable { let version: Int; let entries: [MlsOwnershipEntry]; let next_cursor: MlsOwnershipCursor? }
struct MlsOwnershipMissing: Encodable {
    let id: String; let key_package_ref: Data
    enum CodingKeys: String, CodingKey { case id, key_package_ref }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id)
        try c.encodeE2eeBytes(Array(key_package_ref), forKey: .key_package_ref)
    }
}
struct MlsOwnershipRetirement: Encodable { let missing: [MlsOwnershipMissing] }
struct MlsOwnershipRetired: Decodable { let retired: Int }
struct MlsOwnershipRetry: Codable, Equatable { let cursor: MlsOwnershipCursor?; var attempts: Int; var retryAt: TimeInterval }
struct MlsKeyPackageUploadJob: Codable, Equatable {
    let id: String; var status: String; let createdAt: TimeInterval
    var bytes: [Data] = []; var refs: [Data] = []; var attempts = 0; var retryAt: TimeInterval = 0
    var generationVersion: Int?; var batchSize: Int?; var nativeProviderId: String?
}
struct MlsKeyPackageWork: Codable, Equatable {
    var version = 1; let scope: String
    var cursor: MlsOwnershipCursor?; var attempts = 0; var retryAt: TimeInterval = 0
    var retries: [MlsOwnershipRetry] = []; var leaseId: String?; var leaseUntil: TimeInterval = 0
    var upload: MlsKeyPackageUploadJob?
}

/// Account/device/signer-scoped public work. Native SQLite retains private material.
/// Full-record CAS and readback prevent a stale completion replacing another lease.
final class MlsKeyPackageWorkStore {
    private static let lock = NSRecursiveLock()
    let scope: String
    let url: URL
    init(root: URL, scope: String) {
        self.scope = scope
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        url = root.appendingPathComponent(name + ".json")
    }
    func read() throws -> MlsKeyPackageWork {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return MlsKeyPackageWork(scope: scope) }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw failure("oversize") }
        let value = try JSONDecoder().decode(MlsKeyPackageWork.self, from: data); try validate(value); return value
    }
    func write(expected: MlsKeyPackageWork, next: MlsKeyPackageWork) throws -> MlsKeyPackageWork {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try read() == expected else { throw failure("conflict") }; try validate(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = url.deletingLastPathComponent(); var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 4 * 1024 * 1024 else { throw failure("oversize") }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
        let actual = try read(); guard actual == next else { throw failure("uncertain") }; return actual
    }
    private func validate(_ value: MlsKeyPackageWork) throws {
        guard value.version == 1, value.scope == scope, (0...1_000_000).contains(value.attempts), value.retryAt.isFinite, value.retryAt >= 0,
              value.leaseUntil.isFinite, value.leaseUntil >= 0, value.retries.count <= 16 else { throw failure("invalid") }
        let cursors = [value.cursor].compactMap { $0 } + value.retries.compactMap { $0.cursor }
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for c in cursors { guard UUID(uuidString: c.id) != nil, c.created_at.count <= 64, (date.date(from: c.created_at) ?? ISO8601DateFormatter().date(from: c.created_at)) != nil else { throw failure("cursor_invalid") } }
        for (i, r) in value.retries.enumerated() {
            guard (0...1_000_000).contains(r.attempts), r.retryAt.isFinite, r.retryAt >= 0,
                  !value.retries.prefix(i).contains(where: { $0.cursor == r.cursor }) else { throw failure("retry_invalid") }
        }
        if let job = value.upload {
            guard UUID(uuidString: job.id) != nil, ["preparing", "ready", "retained_private_uncertain", "retained_invalid_or_expired", "retained_server_rejected", "retained_legacy_preparing_unbound", "retained_provider_replaced"].contains(job.status),
                  job.createdAt > 0, job.createdAt.isFinite, (0...1_000_000).contains(job.attempts), job.retryAt >= 0, job.retryAt.isFinite,
                  job.bytes.count <= 100, job.bytes.count == job.refs.count, job.refs.allSatisfy({ $0.count == 32 }),
                  job.bytes.allSatisfy({ !$0.isEmpty }), job.bytes.reduce(0, { $0 + $1.count }) <= 3 * 1024 * 1024 else { throw failure("upload_invalid") }
            if let version = job.generationVersion {
                guard version == 1, let size = job.batchSize, (1...100).contains(size), let provider = job.nativeProviderId,
                      provider.count == 64, provider.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw failure("generation_invalid") }
            }
        }
    }
    static func retryAt(now: TimeInterval, attempts: Int) -> TimeInterval { now + min(300, 30 * pow(2, Double(min(4, max(0, attempts - 1))))) }
    private func failure(_ reason: String) -> Error { ClientError.Unexpected("key_package_work_" + reason) }
}

extension Endpoint {
    func scopedMls(deadline: Date, guardScope: @escaping () throws -> Void) -> Self {
        var copy = self; copy.localMlsGuard = guardScope; copy.localMlsDeadline = deadline; return copy
    }
}
extension Endpoint where ResponseType == MlsOwnershipInventory {
    static func keyPackageOwnership(_ cursor: MlsOwnershipCursor?) -> Self {
        .init(path: .mlsControl("v1/e2ee/key_packages/ownership/inventory"), method: .get,
              query: cursor.map { ["after_id": $0.id, "after_created_at": $0.created_at] }, needDeviceId: true)
    }
}
extension Endpoint where ResponseType == MlsOwnershipRetired {
    static func retireKeyPackageOwnership(_ missing: [MlsOwnershipMissing]) -> Self {
        .init(path: .mlsControl("v1/e2ee/key_packages/ownership/reconcile"), method: .post, body: MlsOwnershipRetirement(missing: missing), needDeviceId: true)
    }
}
