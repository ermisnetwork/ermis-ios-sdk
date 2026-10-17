import CryptoKit
import Foundation

/// Only public MLS protocol artifacts, scoped to the account's provider directory.
/// No identity keys, plaintext or session credentials belong in this record.
struct MlsMembershipMutation: Codable {
    let accountId: String
    let cid: String
    let action: String
    let targets: [String]
    let ghosts: [String]
    let groupId: Data
    let commit: Data
    let welcome: Data
    let ratchetTree: Data
    let groupInfo: Data
    let epoch: Int
    var acknowledged = false
    var needsEpochSync: Bool?
    var canRebase: Bool?
    var supersededCommitHash: Data?
}

private struct MlsMembershipIntent: Codable {
    let cid: String
    let action: String
    let targets: [String]
}

final class MlsMembershipMutationStore {
    private let root: URL
    private static let lock = NSLock()

    init(root: URL) { self.root = root }

    func hasIntent(cid: String) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return FileManager.default.fileExists(atPath: path(cid).appendingPathExtension("preparing").path)
    }

    /// An intent without a full artifact proves the SDK has not submitted a request.
    func begin(cid: String, action: String, targets: Set<String>) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = path(cid).appendingPathExtension("preparing")
        if FileManager.default.fileExists(atPath: url.path) {
            let intent = try JSONDecoder().decode(MlsMembershipIntent.self, from: Data(contentsOf: url))
            guard intent.cid == cid, intent.action == action, Set(intent.targets) == targets else {
                throw ClientError.Unexpected("Resume the original preparing membership operation")
            }
            return true
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(MlsMembershipIntent(cid: cid, action: action, targets: targets.sorted()))
        try bytes.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }; try file.synchronize()
        return false
    }

    func finishIntent(cid: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = path(cid).appendingPathExtension("preparing")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func load(cid: String) throws -> MlsMembershipMutation? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = path(cid)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= 16 * 1024 * 1024 else { throw ClientError.Unexpected("MLS membership artifact exceeds storage budget") }
        let record = try JSONDecoder().decode(MlsMembershipMutation.self, from: bytes)
        guard record.cid == cid, ["add", "remove"].contains(record.action) else {
            throw ClientError.Unexpected("Invalid MLS membership artifact")
        }
        return record
    }

    func save(_ record: MlsMembershipMutation) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var directory = root; try directory.setResourceValues(values)
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= 16 * 1024 * 1024 else { throw ClientError.Unexpected("MLS membership artifact exceeds storage budget") }
        let url = path(record.cid)
        try bytes.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    func remove(cid: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = path(cid)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func path(_ cid: String) -> URL {
        let digest = SHA256.hash(data: Data(cid.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }
}
