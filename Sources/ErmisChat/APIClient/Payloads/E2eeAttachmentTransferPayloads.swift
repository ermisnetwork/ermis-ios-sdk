//
// Copyright 2026 Ermis Inc.
//

import Foundation

struct InitE2eeAttachmentAssetRequest: Codable, Equatable, Sendable {
    let kind: E2eeAttachmentAssetKind
    let cipherSizeEstimate: UInt64

    enum CodingKeys: String, CodingKey {
        case kind
        case cipherSizeEstimate = "cipher_size_estimate"
    }
}

struct InitE2eeAttachmentRequest: Codable, Equatable, Sendable {
    let idempotencyKey: String
    let assets: [InitE2eeAttachmentAssetRequest]

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case assets
    }
}

struct InitE2eeAttachmentMultipartPartResponse: Codable, Equatable, Sendable {
    let partNumber: Int
    let putURL: URL

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case putURL = "put_url"
    }
}

struct InitE2eeAttachmentMultipartResponse: Codable, Equatable, Sendable {
    let multipartUploadId: String
    let partSize: UInt64
    let partCount: Int
    let maxPartRetries: Int
    let retryMaxElapsedSeconds: Int
    let parts: [InitE2eeAttachmentMultipartPartResponse]

    enum CodingKeys: String, CodingKey {
        case multipartUploadId = "multipart_upload_id"
        case partSize = "part_size"
        case partCount = "part_count"
        case maxPartRetries = "max_part_retries"
        case retryMaxElapsedSeconds = "retry_max_elapsed_secs"
        case parts
    }
}

struct InitE2eeAttachmentAssetResponse: Codable, Equatable, Sendable {
    let assetId: String
    let kind: E2eeAttachmentAssetKind
    let uploadMode: E2eeTransferUploadMode?
    let putURL: URL?
    let multipart: InitE2eeAttachmentMultipartResponse?
    let objectKey: String
    let cipherSizeEstimate: UInt64

    var effectiveUploadMode: E2eeTransferUploadMode { uploadMode ?? .singlePut }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case kind
        case uploadMode = "upload_mode"
        case putURL = "put_url"
        case multipart
        case objectKey = "object_key"
        case cipherSizeEstimate = "cipher_size_estimate"
    }
}

struct InitE2eeAttachmentResponse: Codable, Equatable, Sendable {
    let attachmentId: String
    let status: String
    let uploadExpiresAt: String
    let assets: [InitE2eeAttachmentAssetResponse]

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case status
        case uploadExpiresAt = "upload_expires_at"
        case assets
    }
}

struct CompleteE2eeAttachmentPart: Codable, Equatable, Sendable {
    let partNumber: Int
    let eTag: String

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case eTag = "etag"
    }
}

struct CompleteE2eeAttachmentMultipart: Codable, Equatable, Sendable {
    let parts: [CompleteE2eeAttachmentPart]
}

struct CompleteE2eeAttachmentAsset: Codable, Equatable, Sendable {
    let assetId: String
    let multipart: CompleteE2eeAttachmentMultipart?

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case multipart
    }
}

struct CompleteE2eeAttachmentRequest: Codable, Equatable, Sendable {
    let completionLeaseId: String
    let assets: [CompleteE2eeAttachmentAsset]?

    enum CodingKeys: String, CodingKey {
        case completionLeaseId = "completion_lease_id"
        case assets
    }
}

struct CompleteE2eeAttachmentResponse: Decodable, Sendable {
    let attachmentId: String
    let status: String
    let assets: [RawJSON]

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case status
        case assets
    }
}

struct E2eeAttachmentDownloadGrantResponse: Codable, Equatable, Sendable {
    let attachmentId: String
    let assetId: String
    let downloadURL: URL
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case assetId = "asset_id"
        case downloadURL = "download_url"
        case expiresAt = "expires_at"
    }
}

struct QueryE2eeAttachmentsCursor: Codable, Equatable, Sendable {
    let createdAt: String
    let attachmentId: String

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case attachmentId = "attachment_id"
    }
}

struct QueryE2eeAttachmentsRequest: Codable, Equatable, Sendable {
    let limit: Int
    let cursor: QueryE2eeAttachmentsCursor?

    enum CodingKeys: String, CodingKey {
        case limit
        case cursor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limit, forKey: .limit)
        if let cursor {
            try container.encode(cursor, forKey: .cursor)
        } else {
            // Bellboy's first-page contract is explicit: { "limit": 50, "cursor": null }.
            try container.encodeNil(forKey: .cursor)
        }
    }
}

struct QueryE2eeAttachmentAssetProjection: Codable, Equatable, Sendable {
    let assetId: String
    let kind: String
    let cipherSize: UInt64

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case kind
        case cipherSize = "cipher_size"
    }
}

struct QueryE2eeAttachmentProjection: Codable, Equatable, Sendable {
    let attachmentId: String
    let messageId: String
    let cid: String
    let createdByUserId: String
    let createdAt: String
    let updatedAt: String
    let assets: [QueryE2eeAttachmentAssetProjection]

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case messageId = "message_id"
        case cid
        case createdByUserId = "created_by_user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case assets
    }
}

struct QueryE2eeAttachmentsResponse: Codable, Equatable, Sendable {
    let attachments: [QueryE2eeAttachmentProjection]
    let nextCursor: QueryE2eeAttachmentsCursor?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case attachments
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

struct DeleteE2eeAttachmentResponse: Codable, Equatable, Sendable {
    let attachmentId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case status
    }
}

enum E2eeAttachmentAPIContractError: Error, Equatable {
    case invalidIdempotencyKey
    case invalidAssetSet
    case invalidIdentifier
    case invalidExpiry
    case invalidURL
    case invalidStatus
    case invalidQuery
    case invalidCompletion
    case mismatchedAssetSet
    case invalidUploadMode
    case invalidMultipart
}

extension InitE2eeAttachmentRequest {
    static let maximumOriginalCipherSize: UInt64 = 2_147_483_648
    static let maximumPreviewCipherSize: UInt64 = 1_048_576

    func validate() throws {
        guard UUID(uuidString: idempotencyKey) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdempotencyKey
        }

        let kinds = assets.map(\.kind)
        guard (1...2).contains(kinds.count),
              Set(kinds).count == kinds.count,
              kinds.filter({ $0 == .original }).count == 1,
              kinds.allSatisfy({ $0 == .original || $0 == .preview }) else {
            throw E2eeAttachmentAPIContractError.invalidAssetSet
        }

        for asset in assets {
            let maximumSize = asset.kind == .preview
                ? Self.maximumPreviewCipherSize
                : Self.maximumOriginalCipherSize
            guard (24...maximumSize).contains(asset.cipherSizeEstimate) else {
                throw E2eeAttachmentAPIContractError.invalidAssetSet
            }
        }
    }
}

extension QueryE2eeAttachmentsRequest {
    func validate() throws {
        guard (1...100).contains(limit) else {
            throw E2eeAttachmentAPIContractError.invalidQuery
        }
        guard let cursor else { return }
        guard UUID(uuidString: cursor.attachmentId) != nil,
              DateFormatter.Ermis.rfc3339Date(from: cursor.createdAt) != nil else {
            throw E2eeAttachmentAPIContractError.invalidQuery
        }
    }
}

extension CompleteE2eeAttachmentRequest {
    func validate() throws {
        guard UUID(uuidString: completionLeaseId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidCompletion
        }
        guard let assets else { return }

        let assetIds = assets.map(\.assetId)
        guard !assets.isEmpty,
              Set(assetIds).count == assetIds.count,
              assetIds.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw E2eeAttachmentAPIContractError.invalidCompletion
        }
        for asset in assets {
            guard let parts = asset.multipart?.parts, !parts.isEmpty else {
                throw E2eeAttachmentAPIContractError.invalidCompletion
            }
            let numbers = parts.map(\.partNumber)
            guard Set(numbers).count == numbers.count,
                  numbers.allSatisfy({ $0 > 0 }),
                  parts.allSatisfy({ !$0.eTag.isEmpty }) else {
                throw E2eeAttachmentAPIContractError.invalidCompletion
            }
        }
    }
}

extension InitE2eeAttachmentResponse {
    func validate(against request: InitE2eeAttachmentRequest) throws {
        try request.validate()
        let requestedKinds = request.assets.map(\.kind)
        guard UUID(uuidString: attachmentId) != nil,
              assets.allSatisfy({ UUID(uuidString: $0.assetId) != nil }),
              Set(assets.map(\.assetId)).count == assets.count else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        guard DateFormatter.Ermis.rfc3339Date(from: uploadExpiresAt) != nil else {
            throw E2eeAttachmentAPIContractError.invalidExpiry
        }
        guard status == "initiated" else {
            throw E2eeAttachmentAPIContractError.invalidStatus
        }
        guard Set(assets.map(\.kind)) == Set(requestedKinds), assets.count == request.assets.count else {
            throw E2eeAttachmentAPIContractError.mismatchedAssetSet
        }
        let requestedByKind = Dictionary(uniqueKeysWithValues: request.assets.map { ($0.kind, $0) })
        for asset in assets {
            guard requestedByKind[asset.kind]?.cipherSizeEstimate == asset.cipherSizeEstimate else {
                throw E2eeAttachmentAPIContractError.mismatchedAssetSet
            }
            guard !asset.objectKey.isEmpty else {
                throw E2eeAttachmentAPIContractError.invalidUploadMode
            }
            switch asset.effectiveUploadMode {
            case .singlePut:
                guard let putURL = asset.putURL,
                      Self.isSecureHTTPURL(putURL),
                      asset.multipart == nil else {
                    throw E2eeAttachmentAPIContractError.invalidUploadMode
                }
            case .multipart:
                guard asset.kind == .original, asset.putURL == nil, let multipart = asset.multipart else {
                    throw E2eeAttachmentAPIContractError.invalidUploadMode
                }
                try Self.validate(multipart: multipart, cipherSize: asset.cipherSizeEstimate)
            }
        }
    }

    private static func validate(
        multipart: InitE2eeAttachmentMultipartResponse,
        cipherSize: UInt64
    ) throws {
        guard !multipart.multipartUploadId.isEmpty,
              multipart.partSize > 0,
              (1...256).contains(multipart.partCount),
              multipart.maxPartRetries >= 0,
              multipart.retryMaxElapsedSeconds > 0,
              multipart.parts.count == multipart.partCount else {
            throw E2eeAttachmentAPIContractError.invalidMultipart
        }
        let quotient = cipherSize / multipart.partSize
        let remainder = cipherSize % multipart.partSize
        guard quotient <= UInt64(Int.max) else {
            throw E2eeAttachmentAPIContractError.invalidMultipart
        }
        let expectedCount = Int(quotient) + (remainder == 0 ? 0 : 1)
        guard expectedCount == multipart.partCount,
              multipart.parts.map(\.partNumber) == Array(1...multipart.partCount),
              multipart.parts.allSatisfy({ isSecureHTTPURL($0.putURL) }) else {
            throw E2eeAttachmentAPIContractError.invalidMultipart
        }
    }

    private static func isSecureHTTPURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }
}

extension InitE2eeAttachmentAssetResponse {
    /// Converts the server's one-based part list into an exact, gap-free byte plan over the
    /// canonical ciphertext. The transport must never repartition or rewrite those bytes.
    func makePendingMultipartParts() throws -> [PendingE2eeMultipartPart] {
        guard effectiveUploadMode == .multipart,
              let multipart,
              multipart.partSize > 0,
              multipart.parts.count == multipart.partCount,
              multipart.parts.map(\.partNumber) == Array(1...multipart.partCount) else {
            throw E2eeAttachmentAPIContractError.invalidMultipart
        }

        var result: [PendingE2eeMultipartPart] = []
        result.reserveCapacity(multipart.partCount)
        var offset: UInt64 = 0
        for serverPart in multipart.parts {
            guard offset < cipherSizeEstimate else {
                throw E2eeAttachmentAPIContractError.invalidMultipart
            }
            let remaining = cipherSizeEstimate - offset
            let size = min(multipart.partSize, remaining)
            result.append(
                PendingE2eeMultipartPart(
                    number: serverPart.partNumber,
                    offset: offset,
                    size: size,
                    putURL: serverPart.putURL,
                    eTag: nil,
                    taskIdentifier: nil,
                    taskToken: nil,
                    localFileURL: nil
                )
            )
            let (nextOffset, overflow) = offset.addingReportingOverflow(size)
            guard !overflow else { throw E2eeAttachmentAPIContractError.invalidMultipart }
            offset = nextOffset
        }
        guard offset == cipherSizeEstimate else {
            throw E2eeAttachmentAPIContractError.invalidMultipart
        }
        return result
    }
}

extension QueryE2eeAttachmentsResponse {
    func validate() throws {
        var attachmentIds = Set<String>()
        for attachment in attachments {
            guard UUID(uuidString: attachment.attachmentId) != nil,
                  UUID(uuidString: attachment.messageId) != nil,
                  !attachment.cid.isEmpty,
                  !attachment.createdByUserId.isEmpty,
                  DateFormatter.Ermis.rfc3339Date(from: attachment.createdAt) != nil,
                  DateFormatter.Ermis.rfc3339Date(from: attachment.updatedAt) != nil,
                  attachmentIds.insert(attachment.attachmentId).inserted else {
                throw E2eeAttachmentAPIContractError.invalidQuery
            }
            let assetIds = attachment.assets.map(\.assetId)
            guard !assetIds.isEmpty,
                  Set(assetIds).count == assetIds.count,
                  assetIds.allSatisfy({ UUID(uuidString: $0) != nil }),
                  attachment.assets.allSatisfy({ $0.cipherSize >= 24 }) else {
                throw E2eeAttachmentAPIContractError.invalidQuery
            }
        }

        if let nextCursor {
            guard UUID(uuidString: nextCursor.attachmentId) != nil,
                  DateFormatter.Ermis.rfc3339Date(from: nextCursor.createdAt) != nil else {
                throw E2eeAttachmentAPIContractError.invalidQuery
            }
        }
        guard !hasMore || nextCursor != nil else {
            throw E2eeAttachmentAPIContractError.invalidQuery
        }
    }
}

extension E2eeAttachmentDownloadGrantResponse {
    func validate(expectedAttachmentId: String, expectedAssetId: String) throws {
        guard attachmentId == expectedAttachmentId,
              assetId == expectedAssetId,
              UUID(uuidString: attachmentId) != nil,
              UUID(uuidString: assetId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        guard DateFormatter.Ermis.rfc3339Date(from: expiresAt) != nil else {
            throw E2eeAttachmentAPIContractError.invalidExpiry
        }
        guard downloadURL.scheme?.lowercased() == "https", downloadURL.host?.isEmpty == false else {
            throw E2eeAttachmentAPIContractError.invalidURL
        }
    }
}

extension CompleteE2eeAttachmentResponse {
    func validate(expectedAttachmentId: String) throws {
        guard attachmentId == expectedAttachmentId, UUID(uuidString: attachmentId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        guard status == "uploaded", !assets.isEmpty else {
            throw E2eeAttachmentAPIContractError.invalidStatus
        }
    }
}

extension DeleteE2eeAttachmentResponse {
    func validate(expectedAttachmentId: String) throws {
        guard attachmentId == expectedAttachmentId, UUID(uuidString: attachmentId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        guard status == "deleted" else {
            throw E2eeAttachmentAPIContractError.invalidStatus
        }
    }
}
