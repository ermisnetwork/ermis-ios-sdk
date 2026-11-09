import Foundation
import Darwin
import CryptoKit

@_silgen_name("flock")
private func mlsProviderFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum MlsProviderScopeLeaseError: Error, Equatable {
    case alreadyOwned
    case storageUnavailable(Int32)
}

/// A kernel-owned local endpoint retains exclusive ownership without holding a file lock
/// while iOS suspends the process. A short bootstrap lock serializes probe/bind/cleanup;
/// it is never retained with the provider. No TTL, PID heuristic, polling or worker.
final class MlsProviderScopeLease {
    private let descriptor: Int32
    private let databaseURL: URL
    private let socketURL: URL
    private let socketDevice: dev_t
    private let socketInode: ino_t

    init(databaseURL: URL) throws {
        let canonical = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        let gate = try Self.bootstrap(canonical)
        defer { Self.release(gate) }
        let namespace = try Self.namespaceIdentity(descriptor: gate)
        #if os(iOS) && !targetEnvironment(simulator)
        // This signed iPhone consumer rejected AF_UNIX bind. A passive loopback
        // reservation needs no shared file lock. It never accepts or reads traffic.
        // No reuse options or fallback ports: collisions fail closed.
        let handle = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard handle >= 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        var retained = false
        defer { if !retained { Darwin.close(handle) } }
        guard Darwin.fcntl(handle, F_SETFD, FD_CLOEXEC) == 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.ownershipPort(namespace: namespace).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let failure = errno
            if failure == EADDRINUSE { throw MlsProviderScopeLeaseError.alreadyOwned }
            throw MlsProviderScopeLeaseError.storageUnavailable(failure)
        }
        // A bound-only TCP PCB is not a cross-process reservation on iOS. Enter
        // passive LISTEN before publishing ownership; no accept/read worker exists.
        // Backlog zero bounds unsolicited local connections without exposing a protocol.
        guard Darwin.listen(handle, 0) == 0 else {
            let failure = errno
            if failure == EADDRINUSE { throw MlsProviderScopeLeaseError.alreadyOwned }
            throw MlsProviderScopeLeaseError.storageUnavailable(failure)
        }
        self.descriptor = handle
        self.databaseURL = canonical
        self.socketURL = canonical // unused by this kernel endpoint; never unlinked
        self.socketDevice = 0
        self.socketInode = 0
        retained = true
        #else
        let endpoint = try Self.ownershipSocketURL(databaseURL: canonical, namespace: namespace)
        var existing = stat()
        let exists = Darwin.lstat(endpoint.path, &existing) == 0
        if !exists && errno != ENOENT { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        if exists {
            guard (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK), existing.st_uid == geteuid() else {
                throw MlsProviderScopeLeaseError.storageUnavailable(EINVAL)
            }
        }
        let handle = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard handle >= 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        var retained = false
        defer { if !retained { Darwin.close(handle) } }
        guard Darwin.fcntl(handle, F_SETFD, FD_CLOEXEC) == 0 else {
            throw MlsProviderScopeLeaseError.storageUnavailable(errno)
        }
        if exists {
            let result = try Self.withAddress(endpoint.path) { Darwin.connect(handle, $0, $1) }
            if result == 0 { throw MlsProviderScopeLeaseError.alreadyOwned }
            let failure = errno
            // Only a refused kernel endpoint, under the bootstrap lock, proves this
            // socket inode is stale. Any other error preserves the ownership fence.
            guard failure == ECONNREFUSED else { throw MlsProviderScopeLeaseError.storageUnavailable(failure) }
            guard Darwin.unlink(endpoint.path) == 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        }
        guard try Self.withAddress(endpoint.path, { Darwin.bind(handle, $0, $1) }) == 0 else {
            throw MlsProviderScopeLeaseError.storageUnavailable(errno)
        }
        guard Darwin.chmod(endpoint.path, mode_t(0o600)) == 0 else {
            // Descriptor close leaves a safely recoverable stale socket, not a live owner.
            throw MlsProviderScopeLeaseError.storageUnavailable(errno)
        }
        var bound = stat()
        guard Darwin.lstat(endpoint.path, &bound) == 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        self.descriptor = handle
        self.databaseURL = canonical
        self.socketURL = endpoint
        self.socketDevice = bound.st_dev
        self.socketInode = bound.st_ino
        retained = true
        #endif
    }

    deinit {
        #if os(iOS) && !targetEnvironment(simulator)
        Darwin.close(descriptor)
        #else
        // If another initializer briefly owns bootstrap, closing is sufficient. It or
        // the next owner will observe the refused endpoint and retire its stale inode.
        guard let gate = try? Self.bootstrap(databaseURL) else { Darwin.close(descriptor); return }
        defer { Self.release(gate) }
        Darwin.close(descriptor)
        var current = stat()
        if Darwin.lstat(socketURL.path, &current) == 0,
           current.st_dev == socketDevice, current.st_ino == socketInode,
           (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) {
            _ = Darwin.unlink(socketURL.path)
        }
        #endif
    }

    /// Local transport collisions deny admission; they never create another scope owner.
    /// The device/account namespace already owns this process-local endpoint resource.
    static func ownershipPort(databaseURL: URL) throws -> UInt16 {
        ownershipPort(namespace: try namespaceIdentity(databaseURL: databaseURL))
    }

    private static func ownershipPort(namespace: Data) -> UInt16 {
        let digest = SHA256.hash(data: namespace)
        let number = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return UInt16(1024 + number % 48_128)
    }

    private static func namespaceIdentity(databaseURL: URL) throws -> Data {
        let handle = Darwin.open(databaseURL.appendingPathExtension("owner.lock").path,
                                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard handle >= 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        defer { Darwin.close(handle) }
        return try namespaceIdentity(descriptor: handle)
    }

    private static func namespaceIdentity(descriptor: Int32) throws -> Data {
        var file = stat()
        guard Darwin.fstat(descriptor, &file) == 0,
              (file.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), file.st_uid == geteuid(), file.st_ino != 0 else {
            throw MlsProviderScopeLeaseError.storageUnavailable(EINVAL)
        }
        // A URL's resolved spelling can change when SQLite creates the DB on iOS.
        // The permanent owner file is the same filesystem object before/after that
        // boundary and through aliases. Never unlink/replace it while a scope exists.
        return Data("ermis-provider-owner-v1:\(file.st_dev):\(file.st_ino)".utf8)
    }

    private static func bootstrap(_ database: URL) throws -> Int32 {
        let handle = Darwin.open(database.appendingPathExtension("owner.lock").path,
                                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard handle >= 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(errno) }
        guard mlsProviderFlock(handle, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno; Darwin.close(handle)
            if failure == EWOULDBLOCK || failure == EAGAIN { throw MlsProviderScopeLeaseError.alreadyOwned }
            throw MlsProviderScopeLeaseError.storageUnavailable(failure)
        }
        var attributes = stat()
        guard Darwin.fstat(handle, &attributes) == 0,
              (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), attributes.st_uid == geteuid() else {
            release(handle); throw MlsProviderScopeLeaseError.storageUnavailable(EINVAL)
        }
        return handle
    }

    private static func release(_ handle: Int32) {
        _ = mlsProviderFlock(handle, LOCK_UN); Darwin.close(handle)
    }

    static func ownershipSocketURL(databaseURL: URL, namespace: Data? = nil) throws -> URL {
        let canonical = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory: URL
        #if os(iOS) && !targetEnvironment(simulator)
        // AF_UNIX has a short sockaddr path limit. Use the container root plus an
        // opaque scope hash; never change process cwd or the app's shared identity.
        let parts = canonical.pathComponents
        guard let index = parts.firstIndex(of: "AppGroup") ?? parts.firstIndex(of: "Application"),
              parts.indices.contains(index + 1), UUID(uuidString: parts[index + 1]) != nil else {
            throw MlsProviderScopeLeaseError.storageUnavailable(ENAMETOOLONG)
        }
        let root = NSString.path(withComponents: Array(parts.prefix(index + 2)))
        directory = URL(fileURLWithPath: root, isDirectory: true)
        #else
        // Host/simulator processes share this UID-private socket directory. Scope
        // hashes include the complete canonical DB path, including simulator ID.
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ermis-mls-owner-\(geteuid())", isDirectory: true)
        if Darwin.mkdir(directory.path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw MlsProviderScopeLeaseError.storageUnavailable(errno)
        }
        var attributes = stat()
        guard Darwin.lstat(directory.path, &attributes) == 0,
              (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), attributes.st_uid == geteuid(),
              attributes.st_mode & mode_t(0o077) == 0 else { throw MlsProviderScopeLeaseError.storageUnavailable(EACCES) }
        #endif
        // A hash collision denies admission; it can never grant a second owner.
        let name = SHA256.hash(data: try namespace ?? namespaceIdentity(databaseURL: canonical)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let result = directory.appendingPathComponent(".o" + name)
        guard result.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MlsProviderScopeLeaseError.storageUnavailable(ENAMETOOLONG)
        }
        return result
    }

    private static func withAddress<T>(_ path: String, _ action: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw MlsProviderScopeLeaseError.storageUnavailable(ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
