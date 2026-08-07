//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Single source of truth for the MLS, HTTP and WebSocket device identity.
///
/// Values are scoped by user. A value left in `UserDefaults.standard` by an older SDK is imported
/// once and, when it differs from the scoped value, retained only as a receive-side protocol alias.
final class MlsDeviceIdStore {
    static let deviceIdKey = "ermis_mls_device_id"
    static let legacyAliasKey = "ermis_mls_device_id_legacy_aliases"

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults, legacyDefaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
    }

    convenience init(applicationGroupIdentifier: String?) {
        let scopedDefaults = applicationGroupIdentifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.init(defaults: scopedDefaults)
    }

    func canonicalDeviceId(for userId: UserId, createIfNeeded: Bool = true) -> String? {
        lock.withLock {
            var scoped = defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            let legacy = legacyDefaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]

            if let canonical = scoped[userId] {
                if let legacyId = legacy[userId], legacyId != canonical {
                    addLegacyAliasLocked(legacyId, for: userId)
                }
                return canonical
            }

            if let legacyId = legacy[userId] {
                scoped[userId] = legacyId
                defaults.set(scoped, forKey: Self.deviceIdKey)
                return legacyId
            }

            guard createIfNeeded else { return nil }
            let deviceId = "ios-" + UUID().uuidString
            scoped[userId] = deviceId
            defaults.set(scoped, forKey: Self.deviceIdKey)
            return deviceId
        }
    }

    func owns(deviceId: String, for userId: UserId) -> Bool {
        lock.withLock {
            let canonical = (defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String])?[userId]
            if canonical == deviceId { return true }
            let aliases = defaults.dictionary(forKey: Self.legacyAliasKey) as? [String: [String]]
            return aliases?[userId]?.contains(deviceId) == true
        }
    }

    func removeUser(_ userId: UserId) {
        lock.withLock {
            var scoped = defaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            scoped.removeValue(forKey: userId)
            defaults.set(scoped, forKey: Self.deviceIdKey)

            var aliases = defaults.dictionary(forKey: Self.legacyAliasKey) as? [String: [String]] ?? [:]
            aliases.removeValue(forKey: userId)
            defaults.set(aliases, forKey: Self.legacyAliasKey)

            var legacy = legacyDefaults.dictionary(forKey: Self.deviceIdKey) as? [String: String] ?? [:]
            legacy.removeValue(forKey: userId)
            legacyDefaults.set(legacy, forKey: Self.deviceIdKey)
        }
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
