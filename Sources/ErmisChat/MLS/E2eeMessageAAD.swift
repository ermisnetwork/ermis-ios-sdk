//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum E2eeMessageAADError: Error, Equatable {
    case invalidUUID(String)
    case duplicateAttachmentId(String)
    case stringTooLong
    case authenticatedMetadataMismatch
    case authenticatedSendLaneUnavailable
    case missingE2eeGroupId
    case missingEnvelopeCid
    case malformedAAD
    case unsupportedVersion(UInt8)
}

struct E2eeReceivedMessageEnvelope: Equatable, Sendable {
    let forwardCid: String?
    let forwardMessageId: String?
    let forwardParentCid: String?
    let attachmentIds: [String]

    var requiresAAD: Bool {
        forwardCid?.isEmpty == false ||
            forwardMessageId?.isEmpty == false ||
            forwardParentCid?.isEmpty == false ||
            !attachmentIds.isEmpty
    }
}

/// Canonical authenticated metadata shared by Bellboy Web and iOS clients.
struct E2eeMessageAADV1: Equatable {
    static let domain = "BBY_E2EE_MESSAGE_AAD"
    static let version: UInt8 = 1

    let cid: String
    let e2eeGroupId: String
    let messageId: String
    let forwardCid: String?
    let forwardMessageId: String?
    let forwardParentCid: String?
    let attachmentIds: [String]

    init(
        cid: String,
        e2eeGroupId: String,
        messageId: String,
        forwardCid: String? = nil,
        forwardMessageId: String? = nil,
        forwardParentCid: String? = nil,
        attachmentIds: [String] = []
    ) {
        self.cid = cid
        self.e2eeGroupId = e2eeGroupId
        self.messageId = messageId
        self.forwardCid = forwardCid
        self.forwardMessageId = forwardMessageId
        self.forwardParentCid = forwardParentCid
        self.attachmentIds = attachmentIds
    }

    var isRequired: Bool {
        !attachmentIds.isEmpty ||
            nonEmpty(forwardCid) != nil ||
            nonEmpty(forwardMessageId) != nil ||
            nonEmpty(forwardParentCid) != nil
    }

    func encoded() throws -> Data {
        var output = Data()
        try appendString(Self.domain, to: &output)
        output.append(Self.version)
        try appendString(cid, to: &output)
        try appendString(e2eeGroupId, to: &output)
        output.append(try Self.uuidBytes(messageId))
        try appendOptionalString(forwardCid, to: &output)
        try appendOptionalString(forwardMessageId, to: &output)
        try appendOptionalString(forwardParentCid, to: &output)

        let canonicalIds = try Self.canonicalAttachmentIds(attachmentIds)
        appendUInt16(UInt16(canonicalIds.count), to: &output)
        for id in canonicalIds {
            output.append(try Self.uuidBytes(id))
        }
        return output
    }

    /// Decodes the exact cross-platform binary representation returned by OpenMLS. Parsing is
    /// bounded, rejects invalid UTF-8/flags/trailing bytes, and requires canonical attachment
    /// ordering so alternative byte encodings cannot represent the same authenticated metadata.
    static func decoded(from data: Data) throws -> Self {
        var reader = AADReader(data: data)
        guard try reader.readString() == domain else {
            throw E2eeMessageAADError.malformedAAD
        }
        let receivedVersion = try reader.readByte()
        guard receivedVersion == version else {
            throw E2eeMessageAADError.unsupportedVersion(receivedVersion)
        }
        let cid = try reader.readString()
        let groupId = try reader.readString()
        let messageId = try reader.readUUID()
        let forwardCid = try reader.readOptionalString()
        let forwardMessageId = try reader.readOptionalString()
        let forwardParentCid = try reader.readOptionalString()
        let count = Int(try reader.readUInt16())
        var attachmentIds: [String] = []
        attachmentIds.reserveCapacity(count)
        for _ in 0..<count {
            attachmentIds.append(try reader.readUUID())
        }
        guard reader.isAtEnd else {
            throw E2eeMessageAADError.malformedAAD
        }

        let result = Self(
            cid: cid,
            e2eeGroupId: groupId,
            messageId: messageId,
            forwardCid: forwardCid,
            forwardMessageId: forwardMessageId,
            forwardParentCid: forwardParentCid,
            attachmentIds: attachmentIds
        )
        guard try canonicalAttachmentIds(attachmentIds) == attachmentIds,
              try result.encoded() == data else {
            throw E2eeMessageAADError.malformedAAD
        }
        return result
    }

    static func canonicalAttachmentIds(_ ids: [String]) throws -> [String] {
        var keyed: [(id: String, bytes: Data)] = []
        var seen = Set<Data>()
        for id in ids {
            let bytes = try uuidBytes(id)
            guard seen.insert(bytes).inserted else {
                throw E2eeMessageAADError.duplicateAttachmentId(id)
            }
            keyed.append((id, bytes))
        }
        return keyed.sorted { lhs, rhs in
            lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
        }.map(\.id)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    /// Verifies that the AAD authenticated by OpenMLS matches the canonical metadata rebuilt
    /// from the received message envelope. Callers must fail closed before rendering plaintext or
    /// attachment metadata when this throws.
    static func verify(processedAAD: Data, expectedAAD: Data) throws {
        guard constantTimeEqual(processedAAD, expectedAAD) else {
            throw E2eeMessageAADError.authenticatedMetadataMismatch
        }
    }

    private static func uuidBytes(_ value: String) throws -> Data {
        guard let parsed = UUID(uuidString: value) else {
            throw E2eeMessageAADError.invalidUUID(value)
        }
        var uuid = parsed.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private func appendString(_ value: String, to output: inout Data) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw E2eeMessageAADError.stringTooLong
        }
        appendUInt16(UInt16(bytes.count), to: &output)
        output.append(bytes)
    }

    private func appendOptionalString(_ value: String?, to output: inout Data) throws {
        guard let value = nonEmpty(value) else {
            output.append(0)
            return
        }
        output.append(1)
        try appendString(value, to: &output)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func appendUInt16(_ value: UInt16, to output: inout Data) {
        output.append(UInt8((value >> 8) & 0xff))
        output.append(UInt8(value & 0xff))
    }
}

private struct AADReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw E2eeMessageAADError.malformedAAD }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readByte())
        let low = UInt16(try readByte())
        return (high << 8) | low
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw E2eeMessageAADError.malformedAAD
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readString() throws -> String {
        let bytes = try readData(count: Int(readUInt16()))
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw E2eeMessageAADError.malformedAAD
        }
        return value
    }

    mutating func readOptionalString() throws -> String? {
        switch try readByte() {
        case 0:
            return nil
        case 1:
            let value = try readString()
            guard !value.isEmpty else { throw E2eeMessageAADError.malformedAAD }
            return value
        default:
            throw E2eeMessageAADError.malformedAAD
        }
    }

    mutating func readUUID() throws -> String {
        let bytes = try readData(count: 16)
        let values = [UInt8](bytes)
        let uuid = uuid_t(
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        )
        return UUID(uuid: uuid).uuidString.lowercased()
    }
}
