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

    init(createdAt: String, attachmentId: String) {
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

/// Stable, non-sensitive failures that Channel Info can present without exposing storage,
/// Keychain or transport implementation details.
public enum E2eeChannelAttachmentPreviewError: Error, Equatable {
    /// The encrypted manifest/preview cannot be accessed until protected data is available.
    /// This is temporary and must not be presented as integrity failure or missing key material.
    case waitingForUnlock
}

enum E2eeChannelAttachmentPreviewAccessGate {
    static func requireProtectedData(isAvailable: Bool) throws {
        guard isAvailable else {
            throw E2eeChannelAttachmentPreviewError.waitingForUnlock
        }
    }
}

/// Builds the privacy-safe Channel Info attachment telemetry vocabulary.
///
/// Keep this formatter separate from the logger call sites so tests can prove that arbitrary
/// transport and persistence errors never put identifiers, filenames, URLs or key material into
/// logs. Only bounded counts, booleans and fixed categories are emitted.
enum E2eeChannelAttachmentTelemetry {
    enum Operation: String {
        case query
        case join
    }

    enum FailureCategory: String {
        case networkUnavailable
        case serviceTemporarilyUnavailable
        case attachmentBusy
        case retryConflict
        case attachmentTooLarge
        case invalidAttachment
        case attachmentAlreadyBound
        case multipartRequired
        case permissionDenied
        case contractViolation
        case localStateUnavailable
        case unknown
    }

    static func queryStarted(limit: Int, hasCursor: Bool) -> String {
        "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=started limit=\(limit) has_cursor=\(hasCursor)"
    }

    static func querySucceeded(projectionCount: Int, hasMore: Bool) -> String {
        "[E2EE_CHANNEL_ATTACHMENTS] operation=query state=succeeded projection_count=\(projectionCount) has_more=\(hasMore)"
    }

    static func joinSucceeded(
        projectionCount: Int,
        renderableCount: Int,
        unavailableCount: Int
    ) -> String {
        "[E2EE_CHANNEL_ATTACHMENTS] operation=join state=succeeded projection_count=\(projectionCount) renderable_count=\(renderableCount) unavailable_count=\(unavailableCount)"
    }

    static func failed(operation: Operation, error: Error) -> String {
        let failure = failureMetadata(operation: operation, error: error)
        return "[E2EE_CHANNEL_ATTACHMENTS] operation=\(operation.rawValue) state=failed category=\(failure.category.rawValue) retryable=\(failure.retryable)"
    }

    private static func failureMetadata(
        operation: Operation,
        error: Error
    ) -> (category: FailureCategory, retryable: Bool) {
        if operation == .join {
            return (.localStateUnavailable, true)
        }
        if error is E2eeAttachmentAPIContractError {
            return (.contractViolation, false)
        }

        let remote = E2eeAttachmentRemoteError.classify(error)
        let category = FailureCategory(rawValue: remote.category.rawValue) ?? .unknown
        return (category, remote.isRetryable)
    }
}

/// Durable, SDK-owned pagination state for the E2EE attachment projection shown in Channel Info.
///
/// A Channel Info screen has separate Media, File and Voice tabs, but Bellboy exposes one ordered
/// attachment projection. Sharing this controller prevents the tabs from issuing three independent
/// pagination streams and from synthesizing or racing opaque cursors in application code.
@MainActor
public final class E2eeChannelAttachmentListController {
    /// Presentation state derived independently by each Channel Info tab from the shared
    /// projection snapshot. The tab supplies only its filtered row count, so a page failure can
    /// surface without discarding rows already loaded by that tab or its siblings.
    public enum TabPresentationState: Equatable {
        case hidden
        case loading
        case empty
        case retryableFailure
        case terminalFailure
    }

    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// Stable failure semantics for Channel Info pagination. A retryable failure may safely
    /// request the exact same opaque cursor; a terminal failure requires a refresh, permission
    /// change or a newer client contract and must not loop automatically.
    public enum FailureKind: Equatable {
        case retryable
        case terminal
    }

    public struct Snapshot {
        public let items: [E2eeChannelAttachmentListItem]
        public let phase: Phase
        public let hasMore: Bool
        public let unavailableCount: Int
        public let failureKind: FailureKind?

        /// Derives one tab's UI state without mutating or copying the shared pagination stream.
        /// Existing filtered rows remain renderable while another page loads or fails.
        public func tabPresentationState(filteredItemCount: Int) -> TabPresentationState {
            switch phase {
            case .idle, .loading:
                return filteredItemCount == 0 ? .loading : .hidden
            case .loaded:
                return filteredItemCount == 0 && !hasMore ? .empty : .hidden
            case .failed:
                return failureKind == .retryable ? .retryableFailure : .terminalFailure
            }
        }
    }

    typealias PageLoader = (
        _ cid: ChannelId,
        _ limit: Int,
        _ cursor: E2eeChannelAttachmentListCursor?
    ) async throws -> E2eeChannelAttachmentListPage

    typealias FailureClassifier = (Error) -> FailureKind

    public private(set) var snapshot = Snapshot(
        items: [],
        phase: .idle,
        hasMore: true,
        unavailableCount: 0,
        failureKind: nil
    )

    private let cid: ChannelId
    private let pageSize: Int
    private let pageLoader: PageLoader
    private let failureClassifier: FailureClassifier
    private var cursor: E2eeChannelAttachmentListCursor?
    private var pageTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(
        cid: ChannelId,
        pageSize: Int = 50,
        failureClassifier: @escaping FailureClassifier = E2eeChannelAttachmentListController.classifyFailure,
        pageLoader: @escaping PageLoader
    ) {
        self.cid = cid
        self.pageSize = min(max(pageSize, 1), 100)
        self.failureClassifier = failureClassifier
        self.pageLoader = pageLoader
    }

    /// Registers a snapshot observer. The current snapshot is delivered synchronously so a tab
    /// created after another tab loaded pages can render without starting a duplicate query.
    @discardableResult
    public func observe(_ observer: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Starts the first page only when no request or previously loaded snapshot exists.
    public func startIfNeeded() {
        guard snapshot.phase == .idle, snapshot.items.isEmpty else { return }
        loadNextPage()
    }

    /// Discards the current projection and restarts from Bellboy's first page. Results from a
    /// cancelled generation are ignored even if the underlying transport completes later.
    public func refresh() {
        pageTask?.cancel()
        pageTask = nil
        generation &+= 1
        cursor = nil
        snapshot = Snapshot(
            items: [],
            phase: .idle,
            hasMore: true,
            unavailableCount: 0,
            failureKind: nil
        )
        notifyObservers()
        loadNextPage()
    }

    /// Loads one ordered keyset page. Repeated calls while a page is active are coalesced.
    public func loadNextPage() {
        guard pageTask == nil,
              snapshot.hasMore,
              snapshot.phase != .failed else { return }

        let requestCursor = cursor
        let requestGeneration = generation
        snapshot = Snapshot(
            items: snapshot.items,
            phase: .loading,
            hasMore: snapshot.hasMore,
            unavailableCount: snapshot.unavailableCount,
            failureKind: nil
        )
        notifyObservers()

        pageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await pageLoader(cid, pageSize, requestCursor)
                guard !Task.isCancelled, requestGeneration == generation else { return }
                apply(page, previousCursor: requestCursor)
            } catch is CancellationError {
                guard requestGeneration == generation else { return }
                pageTask = nil
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                pageTask = nil
                snapshot = Snapshot(
                    items: snapshot.items,
                    phase: .failed,
                    hasMore: snapshot.hasMore,
                    unavailableCount: snapshot.unavailableCount,
                    failureKind: failureClassifier(error)
                )
                notifyObservers()
            }
        }
    }

    /// Retries the same cursor after a page failure without discarding already loaded items.
    public func retry() {
        guard snapshot.phase == .failed, snapshot.failureKind == .retryable else { return }
        snapshot = Snapshot(
            items: snapshot.items,
            phase: .loaded,
            hasMore: snapshot.hasMore,
            unavailableCount: snapshot.unavailableCount,
            failureKind: nil
        )
        loadNextPage()
    }

    public func cancel() {
        pageTask?.cancel()
        pageTask = nil
        generation &+= 1
        snapshot = Snapshot(
            items: snapshot.items,
            phase: .idle,
            hasMore: snapshot.hasMore,
            unavailableCount: snapshot.unavailableCount,
            failureKind: nil
        )
        notifyObservers()
    }

    private func apply(
        _ page: E2eeChannelAttachmentListPage,
        previousCursor: E2eeChannelAttachmentListCursor?
    ) {
        pageTask = nil
        var knownIds = Set(snapshot.items.map(\.attachmentId))
        let uniqueItems = page.items.filter { knownIds.insert($0.attachmentId).inserted }
        let nextCursor = page.nextCursor
        let canContinue = page.hasMore && nextCursor != nil && nextCursor != previousCursor
        cursor = nextCursor
        snapshot = Snapshot(
            items: snapshot.items + uniqueItems,
            phase: .loaded,
            hasMore: canContinue,
            unavailableCount: snapshot.unavailableCount + page.unavailableCount,
            failureKind: nil
        )
        notifyObservers()
    }

    static func classifyFailure(_ error: Error) -> FailureKind {
        E2eeAttachmentRemoteError.classify(error).isRetryable ? .retryable : .terminal
    }

    private func notifyObservers() {
        let currentSnapshot = snapshot
        observers.values.forEach { $0(currentSnapshot) }
    }
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

        // Bellboy may add projection-only asset kinds in the future. V1 clients authenticate and
        // compare only the kinds they understand, but still fail closed on duplicate IDs and a
        // missing canonical original. Unknown rows must never become renderable metadata.
        let projectedAssetIds = projection.assets.map(\.assetId)
        guard Set(projectedAssetIds).count == projectedAssetIds.count else {
            throw E2eeChannelAttachmentProjectionError.projectionMismatch
        }
        let knownKinds = Set([
            E2eeAttachmentAssetKind.original.rawValue,
            E2eeAttachmentAssetKind.preview.rawValue
        ])
        let knownProjectedAssets = projection.assets.filter { knownKinds.contains($0.kind) }
        guard knownProjectedAssets.filter({ $0.kind == E2eeAttachmentAssetKind.original.rawValue }).count == 1 else {
            throw E2eeChannelAttachmentProjectionError.projectionMismatch
        }
        let projectedAssets = knownProjectedAssets.map {
            "\($0.assetId)|\($0.kind)|\($0.cipherSize)"
        }
        let manifestAssets = manifest.assets.filter { knownKinds.contains($0.kind.rawValue) }.map {
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

/// Loads the authenticated attachment manifests for one Bellboy projection page in a single
/// Core Data fetch. Keeping this operation page-scoped avoids an N+1 fetch for Channel Info and
/// makes the durable `message_id` boundary explicit before any projection can be rendered.
enum E2eeChannelAttachmentDurableManifestStore {
    static func loadPayloads(
        messageIds: Set<String>,
        databaseContainer: DatabaseContainer
    ) async throws -> [String: E2ePayload] {
        try await withCheckedThrowingContinuation { continuation in
            databaseContainer.backgroundReadOnlyContext.perform { [databaseContainer] in
                do {
                    let dtos = try MessageDecryptDTO.load(
                        messageIds: messageIds,
                        context: databaseContainer.backgroundReadOnlyContext
                    )
                    let payloads = dtos.reduce(into: [String: E2ePayload]()) { result, entry in
                        // A corrupt durable payload is treated exactly like a missing manifest:
                        // fail closed for that projection while allowing other rows in the page.
                        result[entry.key] = try? entry.value.asPayload()
                    }
                    continuation.resume(returning: payloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Performs the exact projection-to-manifest join after the page's durable payloads have been
/// loaded. The join is keyed by `message_id`, then `attachment_id`; the mapper additionally
/// authenticates CID and the complete known asset ID/kind/cipher-size set.
enum E2eeChannelAttachmentProjectionJoiner {
    typealias CachedPreview = (data: Data, generation: String)

    static func makeItems(
        projections: [QueryE2eeAttachmentProjection],
        expectedCid: ChannelId,
        payloadsByMessageId: [String: E2ePayload],
        cachedPreview: (_ previewAssetId: String) -> CachedPreview?
    ) -> (items: [E2eeChannelAttachmentListItem], unavailableCount: Int) {
        var unavailableCount = 0
        let items = projections.compactMap { projection -> E2eeChannelAttachmentListItem? in
            do {
                let payload = payloadsByMessageId[projection.messageId]
                let previewAssetId = payload?
                    .e2eeAttachments
                    .first(where: { $0.attachmentId == projection.attachmentId })?
                    .assets
                    .first(where: { $0.kind == .preview })?
                    .assetId
                let preview = previewAssetId.flatMap { cachedPreview($0) }
                return try E2eeChannelAttachmentProjectionMapper.makeItem(
                    projection: projection,
                    expectedCid: expectedCid,
                    payload: payload,
                    cachedPreview: preview
                )
            } catch {
                unavailableCount += 1
                return nil
            }
        }
        return (items, unavailableCount)
    }
}

extension ErmisClient {
    /// Creates the shared Channel Info projection controller for one E2EE channel.
    /// Media, File and Voice tabs should observe the same instance.
    @MainActor
    public func e2eeChannelAttachmentListController(
        for cid: ChannelId,
        pageSize: Int = 50
    ) -> E2eeChannelAttachmentListController {
        E2eeChannelAttachmentListController(cid: cid, pageSize: pageSize) { cid, limit, cursor in
            return try await self.queryE2eeChannelAttachments(in: cid, limit: limit, cursor: cursor)
        }
    }

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
        log.info(
            E2eeChannelAttachmentTelemetry.queryStarted(
                limit: boundedLimit,
                hasCursor: requestCursor != nil
            ),
            subsystems: .mls
        )
        let response: QueryE2eeAttachmentsResponse
        do {
            response = try await apiClient.queryE2eeAttachments(
                cid: cid,
                request: QueryE2eeAttachmentsRequest(limit: boundedLimit, cursor: requestCursor)
            )
            log.info(
                E2eeChannelAttachmentTelemetry.querySucceeded(
                    projectionCount: response.attachments.count,
                    hasMore: response.hasMore
                ),
                subsystems: .mls
            )
        } catch {
            log.error(
                E2eeChannelAttachmentTelemetry.failed(operation: .query, error: error),
                subsystems: .mls
            )
            throw error
        }

        let joined: (items: [E2eeChannelAttachmentListItem], unavailableCount: Int)
        do {
            let payloads = try await E2eeChannelAttachmentDurableManifestStore.loadPayloads(
                messageIds: Set(response.attachments.map(\.messageId)),
                databaseContainer: databaseContainer
            )
            joined = E2eeChannelAttachmentProjectionJoiner.makeItems(
                projections: response.attachments,
                expectedCid: cid,
                payloadsByMessageId: payloads
            ) { previewAssetId in
                E2eeAttachmentPreviewCache.shared.value(for: previewAssetId)
            }
        } catch {
            log.error(
                E2eeChannelAttachmentTelemetry.failed(operation: .join, error: error),
                subsystems: .mls
            )
            throw error
        }
        log.info(
            E2eeChannelAttachmentTelemetry.joinSucceeded(
                projectionCount: response.attachments.count,
                renderableCount: joined.items.count,
                unavailableCount: joined.unavailableCount
            ),
            subsystems: .mls
        )
        return E2eeChannelAttachmentListPage(
            items: joined.items,
            nextCursor: response.nextCursor.map {
                E2eeChannelAttachmentListCursor(
                    createdAt: $0.createdAt,
                    attachmentId: $0.attachmentId
                )
            },
            hasMore: response.hasMore,
            unavailableCount: joined.unavailableCount
        )
    }

    /// Loads only the encrypted preview for one visible E2EE Channel Info item.
    ///
    /// Calls for the same asset are coalesced with timeline/scope-sync hydration and globally
    /// bounded by the preview coordinator. Cancelling the caller removes its waiter; when no
    /// other consumer remains, the underlying preview request is cancelled as well. `nil` means
    /// the authenticated manifest is original-only and is not an error.
    public func loadE2eeChannelAttachmentPreview(
        for item: E2eeChannelAttachmentListItem
    ) async throws -> Data? {
        try await e2eRepository.loadChannelInfoAttachmentPreview(for: item)
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
