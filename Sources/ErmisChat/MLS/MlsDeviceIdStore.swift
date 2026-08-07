//
// Copyright 2026 Ermis Inc.
//

import Foundation
import Security

protocol MlsDeviceIdSecureStoring {
    func load(userId: UserId) throws -> String?
    func save(deviceId: String, userId: UserId) throws
    func remove(userId: UserId) throws
}

struct MlsDeviceIdKeychainStore: MlsDeviceIdSecureStoring {
    private static let service = "network.ermis.chat.mls-device-id.v1"

    func load(userId: UserId) throws -> String? {
        var query = baseQuery(userId: userId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MlsDeviceIdKeychainError(status: status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw MlsDeviceIdKeychainError.invalidData
        }
        return value
    }

    func save(deviceId: String, userId: UserId) throws {
        let data = Data(deviceId.utf8)
        let query = baseQuery(userId: userId)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MlsDeviceIdKeychainError(status: updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MlsDeviceIdKeychainError(status: addStatus)
        }
    }

    func remove(userId: UserId) throws {
        let status = SecItemDelete(baseQuery(userId: userId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MlsDeviceIdKeychainError(status: status)
        }
    }

    private func baseQuery(userId: UserId) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: userId,
            kSecAttrSynchronizable as String: false
        ]
    }
}

private enum MlsDeviceIdKeychainError: Error {
    case status(OSStatus)
    case invalidData

    init(status: OSStatus) {
        self = .status(status)
    }
}

/// Single source of truth for the MLS, HTTP and WebSocket device identity.
///
/// Values are scoped by user. A value left in `UserDefaults.standard` by an older SDK is imported
/// once and, when it differs from the scoped value, retained only as a receive-side protocol alias.
final class MlsDeviceIdStore {
    static let deviceIdKey = "ermis_mls_device_id"
    static let legacyAliasKey = "ermis_mls_device_id_legacy_aliases"
    static let migrationMarkerKey = "ermis_mls_device_id_keychain_migrated"

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults
    private let secureStore: MlsDeviceIdSecureStoring
    private let lock = NSLock()

    init(
        defaults: UserDefaults,
        legacyDefaults: UserDefaults = .standard,
        secureStore: MlsDeviceIdSecureStoring = MlsDeviceIdKeychainStore()
    ) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.secureStore = secureStore
    }

    convenience init(applicationGroupIdentifier: String?) {
        let scopedDefaults = applicationGroupIdentifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.init(defaults: scopedDefaults)
    }

    func canonicalDeviceId(for userId: UserId, createIfNeeded: Bool = true) -> String? {
        lock.withLock {
            let scoped = defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            let legacy = legacyDefaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            let fallbackId = scoped[userId] ?? legacy[userId]
            let migrated = migrationMarkersLocked()[userId] == true

            do {
                if let canonical = try secureStore.load(userId: userId) {
                    markMigratedLocked(userId: userId)
                    addLegacyAliasesLocked(
                        candidates: [scoped[userId], legacy[userId]],
                        canonical: canonical,
                        userId: userId
                    )
                    return canonical
                }
            } catch {
                // Keychain can be unavailable before first unlock. Never replace a known legacy
                // identity while migration is incomplete. Once Keychain became authoritative,
                // fail closed because a restored legacy ID may belong to another installation.
                return migrated ? nil : fallbackId
            }

            let candidate: String
            if !migrated, let fallbackId {
                candidate = fallbackId
            } else {
                guard createIfNeeded else { return nil }
                candidate = "ios-" + UUID().uuidString
            }

            do {
                try secureStore.save(deviceId: candidate, userId: userId)
                guard try secureStore.load(userId: userId) == candidate else { return fallbackId }
                markMigratedLocked(userId: userId)
                if migrated {
                    // A marker-proven missing ThisDeviceOnly item means this is a new
                    // installation. The restored defaults belong to the old MLS device and must
                    // not remain an ownership alias for self-echo/reconciliation decisions.
                    removeLegacyIdentityLocked(userId: userId)
                } else if candidate != fallbackId, let fallbackId {
                    addLegacyAliasLocked(fallbackId, for: userId)
                }
                return candidate
            } catch {
                // If migration cannot be verified, retain the legacy value and leave the marker
                // unset so a later unlocked launch can retry. A fresh install fails closed.
                return fallbackId
            }
        }
    }

    func owns(deviceId: String, for userId: UserId) -> Bool {
        lock.withLock {
            let aliases = defaults.dictionary(forKey: Self.legacyAliasKey) as? [String: [String]]
            do {
                if let canonical = try secureStore.load(userId: userId) {
                    return canonical == deviceId || aliases?[userId]?.contains(deviceId) == true
                }
            } catch {
                // Before first unlock, a legacy ID remains the only authoritative identity.
                guard migrationMarkersLocked()[userId] != true else { return false }
                return legacyDeviceIdsLocked(for: userId).contains(deviceId)
                    || aliases?[userId]?.contains(deviceId) == true
            }

            guard migrationMarkersLocked()[userId] != true else { return false }
            return legacyDeviceIdsLocked(for: userId).contains(deviceId)
                || aliases?[userId]?.contains(deviceId) == true
        }
    }

    func removeUser(_ userId: UserId) {
        lock.withLock {
            try? secureStore.remove(userId: userId)

            var scoped = defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            scoped.removeValue(forKey: userId)
            defaults.set(scoped, forKey: Self.deviceIdKey)

            var aliases = defaults.dictionary(forKey: Self.legacyAliasKey) as? [String: [String]] ?? [:]
            aliases.removeValue(forKey: userId)
            defaults.set(aliases, forKey: Self.legacyAliasKey)

            var legacy = legacyDefaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            legacy.removeValue(forKey: userId)
            legacyDefaults.set(legacy, forKey: Self.deviceIdKey)

            var markers = migrationMarkersLocked()
            markers.removeValue(forKey: userId)
            defaults.set(markers, forKey: Self.migrationMarkerKey)
        }
    }

    private func migrationMarkersLocked() -> [String: Bool] {
        defaults.dictionary(forKey: Self.migrationMarkerKey) as? [String: Bool] ?? [:]
    }

    private func markMigratedLocked(userId: UserId) {
        var markers = migrationMarkersLocked()
        markers[userId] = true
        defaults.set(markers, forKey: Self.migrationMarkerKey)
    }

    private func addLegacyAliasesLocked(
        candidates: [String?],
        canonical: String,
        userId: UserId
    ) {
        for candidate in candidates.compactMap({ $0 }) where candidate != canonical {
            addLegacyAliasLocked(candidate, for: userId)
        }
    }

    private func legacyDeviceIdsLocked(for userId: UserId) -> [String] {
        let scoped = (defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String])?[userId]
        let legacy = (legacyDefaults.dictionary(forKey: Self.deviceIdKey) as? [String: String])?[userId]
        return [scoped, legacy].compactMap { $0 }
    }

    private func removeLegacyIdentityLocked(userId: UserId) {
        var scoped = defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
        scoped.removeValue(forKey: userId)
        defaults.set(scoped, forKey: Self.deviceIdKey)

        var legacy = legacyDefaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
        legacy.removeValue(forKey: userId)
        legacyDefaults.set(legacy, forKey: Self.deviceIdKey)

        var aliases = defaults.dictionary(forKey: Self.legacyAliasKey) as? [String: [String]] ?? [:]
        aliases.removeValue(forKey: userId)
        defaults.set(aliases, forKey: Self.legacyAliasKey)
    }

    private func addLegacyAliasLocked(_ deviceId: String, for userId: UserId) {
        var aliases = defaults.dictionary(forKey: Self.legacyAliasKey) as? [String: [String]] ?? [:]
        var userAliases = aliases[userId] ?? []
        guard !userAliases.contains(deviceId) else { return }
        userAliases.append(deviceId)
        aliases[userId] = userAliases
        defaults.set(aliases, forKey: Self.legacyAliasKey)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
