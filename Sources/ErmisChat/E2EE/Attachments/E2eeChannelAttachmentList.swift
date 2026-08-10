//
// Copyright 2026 Ermis Inc.
//

import CoreData
import Foundation

/// Opaque keyset cursor for the E2EE Channel Info attachment projection.
///
/// The cursor preserves Bellboy's exact `(created_at, attachment_id)` ordering pair. Callers must
/// pass it back unchanged and must not synthesize a cursor from a local timestamp.
public struct E2eeChannelAttachmentListCursor: Equatable {
    fileprivate let createdAt: String
    fileprivate let attachmentId: String

    fileprivate init(createdAt: String, attachmentId: String) {
        self.createdAt = createdAt
        self.attachmentId = attachmentId
    }
}

/// A safe, renderable Channel Info item built by joining Bellboy's opaque projection with the
/// locally decrypted attachment manifest. It intentionally exposes no CEK, nonce or grant URL.
public struct E2eeChannelAttachmentListItem {
    public let attachmentId: String
    public let messageId: MessageId
    public let cid: ChannelId
    public let createdByUserId: String
    public let createdAt: Date
    public let updatedAt: Date
    public let attachment: AnyMessageAttachment
    public let displayName: String?
    public let mimeType: String?
    public let plaintextSize: UInt64?
}

/// One E2EE Channel Info attachment page.
public struct E2eeChannelAttachmentListPage {
    public let items: [E2eeChannelAttachmentListItem]
    public let nextCursor: E2eeChannelAttachmentListCursor?
    public let hasMore: Bool

    /// Number of server projections deliberately omitted because their local authenticated
    /// manifest was unavailable or did not match the projection.
    public let unavailableCount: Int
}

enum E2eeChannelAttachmentProjectionError: Error, Equatable {
    case invalidChannel
    case missingManifest
    case projectionMismatch
    case invalidDate
}

enum E2eeChannelAttachmentProjectionMapper {
    static func makeItem(
        projection: QueryE2eeAttachmentProjection,
        expectedCid: ChannelId,
        payload: E2ePayload?,
        cachedPreview: (data: Data, generation: String)? = nil
    ) throws -> E2eeChannelAttachmentListItem {
        guard projection.cid == expectedCid.rawValue else {
            throw E2eeChannelAttachmentProjectionError.invalidChannel
        }
        guard let payload,
              let manifestIndex = payload.e2eeAttachments.firstIndex(where: {
                  $0.attachmentId == projection.attachmentId
              }) else {
            throw E2eeChannelAttachmentProjectionError.missingManifest
        }
        let manifest = payload.e2eeAttachments[manifestIndex]
        try manifest.validate()

        let projectedAssets = projection.assets.map {
            "\($0.assetId)|\($0.kind)|\($0.cipherSize)"
        }
        let manifestAssets = manifest.assets.map {
            "\($0.assetId)|\($0.kind.rawValue)|\($0.cipherSize)"
        }
        guard Set(projectedAssets) == Set(manifestAssets),
              projectedAssets.count == manifestAssets.count else {
            throw E2eeChannelAttachmentProjectionError.projectionMismatch
        }

        guard let createdAt = DateFormatter.Ermis.rfc3339Date(from: projection.createdAt),
              let updatedAt = DateFormatter.Ermis.rfc3339Date(from: projection.updatedAt),
              let original = manifest.assets.first(where: { $0.kind == .original }) else {
            throw E2eeChannelAttachmentProjectionError.invalidDate
        }
        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(
            for: manifest,
            previewGeneration: cachedPreview?.generation
        )
        let attachment = AnyMessageAttachment(
            id: AttachmentId(cid: expectedCid, messageId: projection.messageId, index: manifestIndex),
            type: renderable.type,
            payload: renderable.data,
            thumbnailData: cachedPreview?.data,
            uploadingState: nil
        )
        let display = original.display ?? [:]
        return E2eeChannelAttachmentListItem(
            attachmentId: projection.attachmentId,
            messageId: projection.messageId,
            cid: expectedCid,
            createdByUserId: projection.createdByUserId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            attachment: attachment,
            displayName: display["name"]?.stringValue,
            mimeType: display["mime_type"]?.stringValue,
            plaintextSize: original.plaintextSize
        )
    }
}

extension ErmisClient {
    /// Queries confirmed E2EE attachments for Channel Info and joins the server projection with
    /// locally persisted decrypted manifests.
    ///
    /// Bellboy does not know filenames, MIME types or content keys. Consequently, an item is
    /// returned only when its authenticated local manifest exists and exactly matches the server
    /// attachment/asset projection. Missing or mismatched rows are counted in `unavailableCount`.
    public func queryE2eeChannelAttachments(
        in cid: ChannelId,
        limit: Int = 50,
        cursor: E2eeChannelAttachmentListCursor? = nil
    ) async throws -> E2eeChannelAttachmentListPage {
        let boundedLimit = min(max(limit, 1), 100)
        let requestCursor = cursor.map {
            QueryE2eeAttachmentsCursor(createdAt: $0.createdAt, attachmentId: $0.attachmentId)
        }
        let response = try await apiClient.queryE2eeAttachments(
            cid: cid,
            request: QueryE2eeAttachmentsRequest(limit: boundedLimit, cursor: requestCursor)
        )

        let payloads: [String: E2ePayload] = try await withCheckedThrowingContinuation { continuation in
            databaseContainer.backgroundReadOnlyContext.perform { [databaseContainer] in
                do {
                    let messageIds = Set(response.attachments.map(\.messageId))
                    let dtos = try MessageDecryptDTO.load(
                        messageIds: messageIds,
                        context: databaseContainer.backgroundReadOnlyContext
                    )
                    let payloads = dtos.reduce(into: [String: E2ePayload]()) { result, entry in
                        result[entry.key] = try? entry.value.asPayload()
                    }
                    continuation.resume(returning: payloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        var unavailableCount = 0
        let items = response.attachments.compactMap { projection -> E2eeChannelAttachmentListItem? in
            do {
                let previewAssetId = payloads[projection.messageId]?
                    .e2eeAttachments
                    .first(where: { $0.attachmentId == projection.attachmentId })?
                    .assets
                    .first(where: { $0.kind == .preview })?
                    .assetId
                let cachedPreview = previewAssetId.flatMap {
                    E2eeAttachmentPreviewCache.shared.value(for: $0)
                }
                return try E2eeChannelAttachmentProjectionMapper.makeItem(
                    projection: projection,
                    expectedCid: cid,
                    payload: payloads[projection.messageId],
                    cachedPreview: cachedPreview
                )
            } catch {
                unavailableCount += 1
                return nil
            }
        }
        log.info(
            "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=succeeded projection_count=\(response.attachments.count) renderable_count=\(items.count) unavailable_count=\(unavailableCount) has_more=\(response.hasMore)",
            subsystems: .mls
        )
        return E2eeChannelAttachmentListPage(
            items: items,
            nextCursor: response.nextCursor.map {
                E2eeChannelAttachmentListCursor(
                    createdAt: $0.createdAt,
                    attachmentId: $0.attachmentId
                )
            },
            hasMore: response.hasMore,
            unavailableCount: unavailableCount
        )
    }

    /// Completion-based convenience for UIKit consumers.
    public func queryE2eeChannelAttachments(
        in cid: ChannelId,
        limit: Int = 50,
        cursor: E2eeChannelAttachmentListCursor? = nil,
        completion: @escaping (Result<E2eeChannelAttachmentListPage, Error>) -> Void
    ) {
        Task {
            do {
                let page = try await queryE2eeChannelAttachments(in: cid, limit: limit, cursor: cursor)
                await MainActor.run { completion(.success(page)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

}
