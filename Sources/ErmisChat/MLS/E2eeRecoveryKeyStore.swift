import Foundation
import CryptoKit
import Security

enum E2eeArchiveError: Error { case invalidData, sessionEnded, generationChanged, cursorRejected, discoveryBudget, pinRequired, vaultConflict, protectedDataUnavailable, storageFailure, safeSkipped }

/// Device-only stash key protects pending epochs; recovery unlock is a separate logout-scoped item.
final class E2eeRecoveryKeyStore: @unchecked Sendable {
    private let service: String
    private let lock = NSRecursiveLock()
    init(namespace: String) { service = "io.ermis.archive.\(namespace)" }
    private func read(_ account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw E2eeArchiveError.protectedDataUnavailable }
        return bytes
    }
    private func save(_ bytes: Data, account: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as [CFString: Any]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData] = bytes; add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw E2eeArchiveError.protectedDataUnavailable }
        } else if status != errSecSuccess { throw E2eeArchiveError.protectedDataUnavailable }
    }
    private func stashKey() throws -> SymmetricKey {
        if let saved = try read("stash") { guard saved.count == 32 else { throw E2eeArchiveError.invalidData }; return SymmetricKey(data: saved) }
        let key = SymmetricKey(size: .bits256)
        try save(key.withUnsafeBytes { Data($0) }, account: "stash")
        return key
    }
    func protect(_ data: Data, purpose: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let sealed = try AES.GCM.seal(data, using: stashKey(), authenticating: Data("\(service):\(purpose)".utf8)).combined else { throw E2eeArchiveError.invalidData }
        return sealed
    }
    func open(_ data: Data, purpose: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: stashKey(), authenticating: Data("\(service):\(purpose)".utf8))
    }
    func loadUnlock() throws -> Data? { lock.lock(); defer { lock.unlock() }; return try read("unlock") }
    func saveUnlock(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; try save(data, account: "unlock") }
    func clearUnlock() throws {
        lock.lock(); defer { lock.unlock() }
        let result = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "unlock"] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw E2eeArchiveError.protectedDataUnavailable }
    }
}

/// Synchronous logout fence also guards capture writes made by the MLS executor.
final class E2eeArchiveSession: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var stopped = false
    func check() throws { lock.lock(); defer { lock.unlock() }; if stopped { throw E2eeArchiveError.sessionEnded } }
    func write<T>(_ work: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw E2eeArchiveError.sessionEnded }; return try work()
    }
    func stop(_ work: () throws -> Void) throws { lock.lock(); defer { lock.unlock() }; stopped = true; try work() }
}
