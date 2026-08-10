//
// Copyright 2026 Ermis Inc.
//

import Foundation

/// A forward-compatible attachment asset kind. V1 sends only `original` and `preview`, while
/// receivers retain unknown values so a future asset kind does not make the whole MLS payload
/// undecodable.
public struct E2eeAttachmentAssetKind: RawRepresentable, Codable, Hashable, Sendable {
    public static let original = Self(rawValue: "original")
    public static let preview = Self(rawValue: "preview")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One framed ciphertext asset inside an encrypted attachment manifest.
public struct E2eeAttachmentManifestAssetV1: Codable, Hashable, Sendable {
    public let assetId: String
    public let kind: E2eeAttachmentAssetKind
    public let cipherSize: UInt64
    public let cipherSha256: String
    public let frameSize: UInt32
    public let contentKey: String
    public let noncePrefix: String
    public let plaintextSize: UInt64?
    public let plaintextSha256: String?
    public let display: [String: RawJSON]?

    public init(
        assetId: String,
        kind: E2eeAttachmentAssetKind,
        cipherSize: UInt64,
        cipherSha256: String,
        frameSize: UInt32,
        contentKey: String,
        noncePrefix: String,
        plaintextSize: UInt64? = nil,
        plaintextSha256: String? = nil,
        display: [String: RawJSON]? = nil
    ) {
        self.assetId = assetId
        self.kind = kind
        self.cipherSize = cipherSize
        self.cipherSha256 = cipherSha256
        self.frameSize = frameSize
        self.contentKey = contentKey
        self.noncePrefix = noncePrefix
        self.plaintextSize = plaintextSize
        self.plaintextSha256 = plaintextSha256
        self.display = display
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case kind
        case cipherSize = "cipher_size"
        case cipherSha256 = "cipher_sha256"
        case frameSize = "frame_size"
        case contentKey = "content_key"
        case noncePrefix = "nonce_prefix"
        case plaintextSize = "plaintext_size"
        case plaintextSha256 = "plaintext_sha256"
        case display
    }
}

/// The attachment manifest encrypted inside the MLS application payload. Bellboy sees only the
/// canonical attachment ID set carried by the authenticated message envelope.
public struct E2eeAttachmentManifestV1: Codable, Hashable, Sendable {
    public static let version = 1

    public let version: Int
    public let attachmentId: String
    public let assets: [E2eeAttachmentManifestAssetV1]

    public init(
        attachmentId: String,
        assets: [E2eeAttachmentManifestAssetV1]
    ) {
        self.version = Self.version
        self.attachmentId = attachmentId
        self.assets = assets
    }

    init(
        version: Int,
        attachmentId: String,
        assets: [E2eeAttachmentManifestAssetV1]
    ) {
        self.version = version
        self.attachmentId = attachmentId
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case version
        case attachmentId = "attachment_id"
        case assets
    }
}

enum E2eeAttachmentManifestValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidAttachmentId(String)
    case invalidAssetId(String)
    case duplicateAssetId(String)
    case invalidAssetCount(Int)
    case missingOriginalAsset
    case duplicateAssetKind(String)
    case invalidFrameSize(UInt32)
    case invalidContentKey
    case invalidNoncePrefix
    case invalidSha256(String)
    case invalidCipherSize(UInt64)
    case invalidPlaintextSize(UInt64)
}

extension E2eeAttachmentManifestV1 {
    /// Validates sender-controlled manifest metadata before it can be rendered or used for file
    /// access. Unknown asset kinds remain decodable but V1 still requires exactly one original.
    func validate() throws {
        guard version == Self.version else {
            throw E2eeAttachmentManifestValidationError.unsupportedVersion(version)
        }
        guard UUID(uuidString: attachmentId) != nil else {
            throw E2eeAttachmentManifestValidationError.invalidAttachmentId(attachmentId)
        }
        guard (1...2).contains(assets.count) else {
            throw E2eeAttachmentManifestValidationError.invalidAssetCount(assets.count)
        }

        var assetIds = Set<UUID>()
        var knownKinds = Set<String>()
        for asset in assets {
            guard let assetId = UUID(uuidString: asset.assetId) else {
                throw E2eeAttachmentManifestValidationError.invalidAssetId(asset.assetId)
            }
            guard assetIds.insert(assetId).inserted else {
                throw E2eeAttachmentManifestValidationError.duplicateAssetId(asset.assetId)
            }
            if asset.kind == .original || asset.kind == .preview {
                guard knownKinds.insert(asset.kind.rawValue).inserted else {
                    throw E2eeAttachmentManifestValidationError.duplicateAssetKind(asset.kind.rawValue)
                }
            }
            guard asset.frameSize == UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize) else {
                throw E2eeAttachmentManifestValidationError.invalidFrameSize(asset.frameSize)
            }
            guard Data(base64Encoded: asset.contentKey)?.count == E2eeAttachmentFrameCryptoV1.keySize else {
                throw E2eeAttachmentManifestValidationError.invalidContentKey
            }
            guard Data(base64Encoded: asset.noncePrefix)?.count == E2eeAttachmentFrameCryptoV1.noncePrefixSize else {
                throw E2eeAttachmentManifestValidationError.invalidNoncePrefix
            }
            guard Self.isSha256Hex(asset.cipherSha256) else {
                throw E2eeAttachmentManifestValidationError.invalidSha256(asset.cipherSha256)
            }
            if let plaintextSha256 = asset.plaintextSha256,
               !Self.isSha256Hex(plaintextSha256) {
                throw E2eeAttachmentManifestValidationError.invalidSha256(plaintextSha256)
            }
            guard asset.cipherSize >= UInt64(E2eeAttachmentFrameCryptoV1.emptyCiphertextSize) else {
                throw E2eeAttachmentManifestValidationError.invalidCipherSize(asset.cipherSize)
            }
            if let plaintextSize = asset.plaintextSize {
                let expected = try E2eeAttachmentFrameCryptoV1.estimatedCiphertextSize(
                    plaintextSize: plaintextSize,
                    frameSize: Int(asset.frameSize)
                )
                guard expected == asset.cipherSize else {
                    throw E2eeAttachmentManifestValidationError.invalidPlaintextSize(plaintextSize)
                }
            }
        }

        guard knownKinds.contains(E2eeAttachmentAssetKind.original.rawValue) else {
            throw E2eeAttachmentManifestValidationError.missingOriginalAsset
        }
    }

    private static func isSha256Hex(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

extension Array where Element == E2eeAttachmentManifestV1 {
    /// Verifies that the encrypted manifest and the Bellboy envelope authenticate the exact same
    /// canonical attachment set. A mismatch must fail closed before any attachment is rendered.
    func verifyCanonicalAttachmentIds(_ envelopeIds: [String]) throws {
        for manifest in self {
            try manifest.validate()
        }
        let manifestIds = map(\.attachmentId)
        let canonicalManifest = try E2eeMessageAADV1.canonicalAttachmentIds(manifestIds)
        let canonicalEnvelope = try E2eeMessageAADV1.canonicalAttachmentIds(envelopeIds)
        guard canonicalManifest == canonicalEnvelope else {
            throw E2eeMessageAADError.authenticatedMetadataMismatch
        }
    }
}
