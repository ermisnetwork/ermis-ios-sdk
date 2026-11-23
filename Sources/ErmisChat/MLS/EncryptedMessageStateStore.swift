// Copyright 2026 Ermis Inc.

import Foundation
import CryptoKit

/// Receive presentation only; pending protocol/connectivity is `.encrypted`.
public enum EncryptedMessageState {
    case encrypted, decrypting, failed, unavailable
    public static let didChange = Notification.Name("network.ermis.encrypted-message-state.changed")
}

/// One database owner, bounded metadata only. No plaintext or private provider bytes.
final class EncryptedMessageStateStore {
    struct Key: Hashable {
        let cid: String
        let id: String
        let cipherHash: Data
        init(cid: String, id: String, ciphertext: Data) {
            self.cid = cid
            self.id = id
            cipherHash = Data(SHA256.hash(data: ciphertext))
        }
    }
    private let lock = NSLock()
    private var states: [Key: EncryptedMessageState] = [:]
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int = 2048) { self.capacity = max(1, capacity) }

    func state(for key: Key) -> EncryptedMessageState {
        lock.lock(); defer { lock.unlock() }
        return states[key] ?? .encrypted
    }

    func begin(_ key: Key) {
        set(.decrypting, for: key, onlyIfPending: true)
    }

    func set(_ state: EncryptedMessageState, for key: Key, onlyIfPending: Bool = false) {
        lock.lock()
        let previous = states[key] ?? .encrypted
        guard previous != state, !onlyIfPending || previous == .encrypted else { lock.unlock(); return }
        if state == .encrypted {
            states.removeValue(forKey: key)
            order.removeAll { $0 == key }
        } else {
            if states[key] == nil { order.append(key) }
            states[key] = state
            while order.count > capacity { states.removeValue(forKey: order.removeFirst()) }
        }
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: EncryptedMessageState.didChange, object: self, userInfo: ["key": key])
        }
    }
}
