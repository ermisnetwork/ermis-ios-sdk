import Foundation

/// Archive wire JSON preserves UInt64 generation/epoch and accepts both Bellboy byte encodings.
indirect enum E2eeArchiveWire: Codable, Sendable {
    case object([String: E2eeArchiveWire]), array([E2eeArchiveWire]), string(String), uint(UInt64), decimal(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(UInt64.self) { self = .uint(v) }
        else if let v = try? c.decode(Double.self) { self = .decimal(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .uint(let v): try c.encode(v)
        case .decimal(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self { if case .object(let d) = self { return d[key] ?? .null }; return .null }
    var dictionary: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var array: [Self] { if case .array(let v) = self { return v }; return [] }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: UInt64? { if case .uint(let v) = self { return v }; return nil }
    var boolean: Bool { if case .bool(let v) = self { return v }; return false }
    var bytes: Data? {
        if let string { return Data(base64Encoded: string) }
        if case .array(let values) = self {
            var result = Data()
            for value in values { guard let n = value.number, n <= 255 else { return nil }; result.append(UInt8(n)) }
            return result
        }
        return nil
    }
    static func bytes(_ value: Data) -> Self { .string(value.base64EncodedString()) }
}

enum E2eeArchiveOperation: String, Codable {
    case upload = "", recipients = "recipients/query", availability = "availability/query"
    case material = "material/query", ciphertexts = "ciphertexts/query"
}

extension Endpoint {
    static func recoveryVault(body: E2eeArchiveWire? = nil) -> Endpoint<E2eeArchiveWire> {
        .init(path: .recoveryVault, method: body == nil ? .get : .post, body: body, needDeviceId: true)
    }
    static func epochArchive(cid: ChannelId, operation: E2eeArchiveOperation, body: E2eeArchiveWire) -> Endpoint<E2eeArchiveWire> {
        .init(path: .epochArchive(cid, operation), method: .post, body: body, needDeviceId: true)
    }
}
