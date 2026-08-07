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
