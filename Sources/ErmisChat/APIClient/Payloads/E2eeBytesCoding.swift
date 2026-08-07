//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// Bellboy's negotiated wire representation for serialized E2EE bytes.
enum E2eeByteWireFormat {
    static let headerName = "X-Ermis-E2EE-Bytes"
    static let headerValue = "base64"
    static let webSocketQueryName = "e2ee_bytes"
}

enum E2eeBytesCodingError: Error, Equatable {
    case invalidBase64
    case invalidLegacyByte(Double)
    case invalidWireType
}

/// Count-only migration telemetry. Dimensions are restricted to schema field names and a fixed
/// source enum; no payload bytes, identifiers, keys, or URLs can enter the log message.
enum E2eeLegacyByteTelemetry {
    enum Source: String {
        case wireDecode = "wire_decode"
        case durableMigration = "durable_migration"
        case offlineRequestReplay = "offline_request_replay"
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
    }

    private static let state = State()
    private static let allowedFields: Set<String> = [
        "mls_ciphertext",
        "commit",
        "welcome",
        "ratchet_tree",
        "group_info",
        "proposal",
        "key_package",
        "key_package_ref",
        "key_packages"
    ]

    static func record(field: String, source: Source) {
        let safeField = allowedFields.contains(field) ? field : "unknown"
        let key = "\(source.rawValue):\(safeField)"
        let occurrence: Int

        state.lock.lock()
        occurrence = state.counts[key, default: 0] + 1
        state.counts[key] = occurrence
        state.lock.unlock()

        // Emit the first observation and then powers of two to retain a useful usage signal
        // without producing one log line per decoded payload during a migration window.
        guard occurrence == 1 || occurrence.nonzeroBitCount == 1 else { return }
        log.warning(
            "[E2eTelemetry] inbound_legacy_byte_array source=\(source.rawValue) field=\(safeField) occurrences=\(occurrence)",
            subsystems: .mls
        )
    }

    static func count(field: String, source: Source) -> Int {
        let safeField = allowedFields.contains(field) ? field : "unknown"
        let key = "\(source.rawValue):\(safeField)"
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.counts[key, default: 0]
    }

    static func resetForTesting() {
        state.lock.lock()
        state.counts.removeAll()
        state.lock.unlock()
    }
}

/// Field-scoped E2EE byte codec.
///
/// New output is always canonical RFC 4648 standard, padded base64. Input temporarily accepts
/// both that representation and the legacy JSON number array so persisted pre-migration data can
/// still be replayed after an SDK upgrade.
enum E2eeBytesCodec {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    static func decodeCanonicalBase64(_ value: String) throws -> [UInt8] {
        guard value.utf8.count.isMultiple(of: 4),
              let data = Data(base64Encoded: value, options: []),
              data.base64EncodedString() == value else {
            throw E2eeBytesCodingError.invalidBase64
        }
        return data.uint8Array
    }

    static func decodeLegacy(_ values: [Double]) throws -> [UInt8] {
        try values.map { value in
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= 0,
                  value <= Double(UInt8.max) else {
                throw E2eeBytesCodingError.invalidLegacyByte(value)
            }
            return UInt8(value)
        }
    }
}

private struct E2eeWireBytes: Codable {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            bytes = try E2eeBytesCodec.decodeCanonicalBase64(value)
            return
        }
        if let values = try? container.decode([Double].self) {
            bytes = try E2eeBytesCodec.decodeLegacy(values)
            let field = decoder.codingPath.reversed()
                .map(\.stringValue)
                .first(where: E2eeLegacyByteTelemetry.allowedField)
                ?? "unknown"
            E2eeLegacyByteTelemetry.record(field: field, source: .wireDecode)
            return
        }
        throw E2eeBytesCodingError.invalidWireType
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(E2eeBytesCodec.encode(bytes))
    }
}

private extension E2eeLegacyByteTelemetry {
    static func allowedField(_ value: String) -> Bool {
        allowedFields.contains(value)
    }
}

extension KeyedEncodingContainer {
    mutating func encodeE2eeBytes(_ value: [UInt8], forKey key: Key) throws {
        try encode(E2eeWireBytes(bytes: value), forKey: key)
    }

    mutating func encodeE2eeBytesIfPresent(_ value: [UInt8]?, forKey key: Key) throws {
        guard let value else { return }
        try encodeE2eeBytes(value, forKey: key)
    }

    mutating func encodeE2eeByteVector(_ value: [[UInt8]], forKey key: Key) throws {
        try encode(value.map(E2eeWireBytes.init(bytes:)), forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeE2eeBytes(forKey key: Key) throws -> [UInt8] {
        try decode(E2eeWireBytes.self, forKey: key).bytes
    }

    func decodeE2eeBytesIfPresent(forKey key: Key) throws -> [UInt8]? {
        try decodeIfPresent(E2eeWireBytes.self, forKey: key)?.bytes
    }

    func decodeE2eeByteVector(forKey key: Key) throws -> [[UInt8]] {
        try decode([E2eeWireBytes].self, forKey: key).map(\.bytes)
    }
}

/// Canonicalizes only known E2EE byte fields. Other JSON is preserved byte-for-byte semantically.
/// This makes durable-event deduplication representation-independent and upgrades old queued E2EE
/// request bodies without introducing a generic recursive byte-array conversion.
enum E2eeWireJSONCanonicalizer {
    private static let byteFieldNames: Set<String> = [
        "mls_ciphertext",
        "commit",
        "welcome",
        "ratchet_tree",
        "group_info",
        "proposal",
        "key_package",
        "key_package_ref"
    ]

    static func canonicalizeJSONData(
        _ data: Data,
        recordLegacyUsage: Bool = true
    ) throws -> Data {
        let raw = try JSONDecoder().decode(RawJSON.self, from: data)
        let source: E2eeLegacyByteTelemetry.Source? = recordLegacyUsage ? .durableMigration : nil
        return try encode(canonicalize(raw, legacySource: source))
    }

    static func canonicalizeMessageRequestJSONData(_ data: Data) throws -> Data {
        let raw = try JSONDecoder().decode(RawJSON.self, from: data)
        guard case .dictionary(var root) = raw else {
            throw E2eeBytesCodingError.invalidWireType
        }

        if let message = root["message"] {
            root["message"] = try canonicalizeMessageObject(message, legacySource: .offlineRequestReplay)
            if let oldMessage = root["old_message"], !oldMessage.isNil {
                root["old_message"] = try canonicalizeMessageObject(
                    oldMessage,
                    legacySource: .offlineRequestReplay
                )
            }
        } else {
            return try encode(canonicalizeMessageObject(raw, legacySource: .offlineRequestReplay))
        }
        return try encode(.dictionary(root))
    }

    static func canonicalize(
        _ raw: RawJSON,
        legacySource: E2eeLegacyByteTelemetry.Source? = nil
    ) throws -> RawJSON {
        switch raw {
        case .dictionary(let dictionary):
            var result: [String: RawJSON] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                if byteFieldNames.contains(key) {
                    result[key] = try canonicalByteField(
                        value,
                        field: key,
                        legacySource: legacySource
                    )
                } else if key == "key_packages" {
                    result[key] = try canonicalByteVector(
                        value,
                        field: key,
                        legacySource: legacySource
                    )
                } else {
                    result[key] = try canonicalize(value, legacySource: legacySource)
                }
            }
            return .dictionary(result)
        case .array(let values):
            return .array(try values.map { try canonicalize($0, legacySource: legacySource) })
        default:
            return raw
        }
    }

    private static func canonicalByteField(
        _ raw: RawJSON,
        field: String,
        legacySource: E2eeLegacyByteTelemetry.Source?
    ) throws -> RawJSON {
        switch raw {
        case .string(let value):
            let bytes = try E2eeBytesCodec.decodeCanonicalBase64(value)
            return .string(E2eeBytesCodec.encode(bytes))
        case .array(let values):
            let numbers = try values.map { value -> Double in
                guard case .number(let number) = value else {
                    throw E2eeBytesCodingError.invalidWireType
                }
                return number
            }
            let bytes = try E2eeBytesCodec.decodeLegacy(numbers)
            if let legacySource {
                E2eeLegacyByteTelemetry.record(field: field, source: legacySource)
            }
            return .string(E2eeBytesCodec.encode(bytes))
        case .nil:
            return .nil
        default:
            throw E2eeBytesCodingError.invalidWireType
        }
    }

    private static func canonicalByteVector(
        _ raw: RawJSON,
        field: String,
        legacySource: E2eeLegacyByteTelemetry.Source?
    ) throws -> RawJSON {
        guard case .array(let values) = raw else {
            throw E2eeBytesCodingError.invalidWireType
        }
        return .array(try values.map {
            try canonicalByteField($0, field: field, legacySource: legacySource)
        })
    }

    private static func canonicalizeMessageObject(
        _ raw: RawJSON,
        legacySource: E2eeLegacyByteTelemetry.Source
    ) throws -> RawJSON {
        guard case .dictionary(var message) = raw else {
            throw E2eeBytesCodingError.invalidWireType
        }
        if let ciphertext = message["mls_ciphertext"], !ciphertext.isNil {
            message["mls_ciphertext"] = try canonicalByteField(
                ciphertext,
                field: "mls_ciphertext",
                legacySource: legacySource
            )
        }
        return .dictionary(message)
    }

    private static func encode(_ raw: RawJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(raw)
    }
}

enum E2eeLegacyRequestBodyNormalizer {
    static func normalizeIfNeeded(_ body: Data, path: EndpointPath) throws -> Data {
        switch path {
        case .sendMessage, .sendE2eMessage, .editMessage, .editE2eMessage:
            return try E2eeWireJSONCanonicalizer.canonicalizeMessageRequestJSONData(body)
        default:
            return body
        }
    }
}
