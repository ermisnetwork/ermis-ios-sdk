//
// Copyright 2026 Ermis Inc.
//

import CryptoKit
import Foundation
import Security

enum E2eeAttachmentWrappingKeyAccess: Equatable {
    case mainApp
    case readOnlyExtension
}

enum E2eeAttachmentWrappingKeyError: Error, Equatable {
    case waitingForFirstUnlock
    case temporarilyUnavailable(OSStatus)
    case wrappingKeyNotInitialized
    case localKeyUnavailableAfterReinstall
    case corruptKeyRecord
    case corruptSealedMaterial
    case mutationForbiddenOutsideMainApp
    case randomGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)
}

struct E2eeAttachmentSecretMaterial: Codable, Equatable, Sendable {
    let contentKey: Data
    let noncePrefix: Data

    init(contentKey: Data, noncePrefix: Data) throws {
        guard contentKey.count == E2eeAttachmentFrameCryptoV1.keySize,
              noncePrefix.count == E2eeAttachmentFrameCryptoV1.noncePrefixSize else {
            throw E2eeAttachmentWrappingKeyError.corruptSealedMaterial
        }
        self.contentKey = contentKey
        self.noncePrefix = noncePrefix
    }
}

/// Persisted beside pending transfer metadata. It contains no plaintext key material.
struct E2eeSealedAttachmentSecret: Codable, Equatable, Sendable {
    let wrappingKeyVersion: Int
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

private struct E2eeAttachmentWrappingKeyRecord: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let key: Data

    func validate() throws {
        guard version > 0, key.count == E2eeAttachmentFrameCryptoV1.keySize else {
            throw E2eeAttachmentWrappingKeyError.corruptKeyRecord
        }
    }
}

enum E2eeAttachmentKeychainAddResult {
    case inserted
    case duplicate
}

protocol E2eeAttachmentKeychainStoring {
    func load() throws -> Data?
    func addAtomically(_ data: Data) throws -> E2eeAttachmentKeychainAddResult
}

struct E2eeAttachmentKeychainStore: E2eeAttachmentKeychainStoring {
    let service: String

    init(namespace: String = Bundle.main.bundleIdentifier ?? "network.ermis.chat") {
        service = namespace + ".e2ee-attachment-wrapping-key.v1"
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw E2eeAttachmentKeychainStatusError(status: status)
        }
        return data
    }

    func addAtomically(_ data: Data) throws -> E2eeAttachmentKeychainAddResult {
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return .duplicate }
        guard status == errSecSuccess else {
            throw E2eeAttachmentKeychainStatusError(status: status)
        }
        return .inserted
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "installation",
            kSecAttrSynchronizable as String: false
        ]
    }
}

struct E2eeAttachmentKeychainStatusError: Error, Equatable {
    let status: OSStatus
}

/// Owns the per-install AES wrapping key used to seal attachment CEKs and nonce prefixes before
/// they enter the durable transfer store. Only a main-app instance may create the key. Extensions
/// use read-only access and hand work to the main app when the key has not been initialized.
final class E2eeAttachmentWrappingKeyStore {
    static let initializedMarker = "ermis_e2ee_attachment_wrapping_key_initialized_v1"

    private let keychain: E2eeAttachmentKeychainStoring
    private let defaults: UserDefaults
    private let access: E2eeAttachmentWrappingKeyAccess
    private let lock = NSLock()

    init(
        keychain: E2eeAttachmentKeychainStoring = E2eeAttachmentKeychainStore(),
        defaults: UserDefaults = .standard,
        access: E2eeAttachmentWrappingKeyAccess
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.access = access
    }

    func seal(_ material: E2eeAttachmentSecretMaterial) throws -> E2eeSealedAttachmentSecret {
        try lock.withLock {
            let record = try loadOrCreateRecordLocked()
            let plaintext = try JSONEncoder.default.encode(material)
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: record.key))
            return E2eeSealedAttachmentSecret(
                wrappingKeyVersion: record.version,
                nonce: box.nonce.withUnsafeBytes { Data($0) },
                ciphertext: box.ciphertext,
                tag: box.tag
            )
        }
    }

    func unseal(_ sealed: E2eeSealedAttachmentSecret) throws -> E2eeAttachmentSecretMaterial {
        try lock.withLock {
            let record = try loadExistingRecordLocked()
            guard sealed.wrappingKeyVersion == record.version else {
                throw E2eeAttachmentWrappingKeyError.localKeyUnavailableAfterReinstall
            }
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: sealed.nonce),
                    ciphertext: sealed.ciphertext,
                    tag: sealed.tag
                )
                let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: record.key))
                return try JSONDecoder.default.decode(E2eeAttachmentSecretMaterial.self, from: plaintext)
            } catch let error as E2eeAttachmentWrappingKeyError {
                throw error
            } catch {
                throw E2eeAttachmentWrappingKeyError.corruptSealedMaterial
            }
        }
    }

    private func loadOrCreateRecordLocked() throws -> E2eeAttachmentWrappingKeyRecord {
        if let existing = try loadRecordLocked() {
            markInitializedLocked()
            return existing
        }
        guard !defaults.bool(forKey: Self.initializedMarker) else {
            throw E2eeAttachmentWrappingKeyError.localKeyUnavailableAfterReinstall
        }
        guard access == .mainApp else {
            throw E2eeAttachmentWrappingKeyError.mutationForbiddenOutsideMainApp
        }

        let candidate = try makeRecord()
        let encoded = try JSONEncoder.default.encode(candidate)
        switch try keychain.addAtomically(encoded) {
        case .inserted:
            break
        case .duplicate:
            // Another main-app thread/process won the race. Never overwrite or rotate it.
            break
        }
        guard let authoritative = try loadRecordLocked() else {
            throw E2eeAttachmentWrappingKeyError.corruptKeyRecord
        }
        markInitializedLocked()
        return authoritative
    }

    private func loadExistingRecordLocked() throws -> E2eeAttachmentWrappingKeyRecord {
        if let record = try loadRecordLocked() {
            markInitializedLocked()
            return record
        }
        if defaults.bool(forKey: Self.initializedMarker) {
            throw E2eeAttachmentWrappingKeyError.localKeyUnavailableAfterReinstall
        }
        throw E2eeAttachmentWrappingKeyError.wrappingKeyNotInitialized
    }

    private func loadRecordLocked() throws -> E2eeAttachmentWrappingKeyRecord? {
        do {
            guard let data = try keychain.load() else { return nil }
            let record = try JSONDecoder.default.decode(E2eeAttachmentWrappingKeyRecord.self, from: data)
            try record.validate()
            return record
        } catch let error as E2eeAttachmentWrappingKeyError {
            throw error
        } catch let error as E2eeAttachmentKeychainStatusError {
            throw classify(status: error.status)
        } catch is DecodingError {
            throw E2eeAttachmentWrappingKeyError.corruptKeyRecord
        } catch {
            throw E2eeAttachmentWrappingKeyError.corruptKeyRecord
        }
    }

    private func makeRecord() throws -> E2eeAttachmentWrappingKeyRecord {
        var bytes = Data(count: E2eeAttachmentFrameCryptoV1.keySize)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                E2eeAttachmentFrameCryptoV1.keySize,
                baseAddress
            )
        }
        guard status == errSecSuccess else {
            throw E2eeAttachmentWrappingKeyError.randomGenerationFailed(status)
        }
        return E2eeAttachmentWrappingKeyRecord(
            version: E2eeAttachmentWrappingKeyRecord.currentVersion,
            key: bytes
        )
    }

    private func classify(status: OSStatus) -> E2eeAttachmentWrappingKeyError {
        switch status {
        case errSecInteractionNotAllowed:
            return .waitingForFirstUnlock
        case errSecNotAvailable:
            return .temporarilyUnavailable(status)
        default:
            return .keychainFailure(status)
        }
    }

    private func markInitializedLocked() {
        defaults.set(true, forKey: Self.initializedMarker)
    }
}
