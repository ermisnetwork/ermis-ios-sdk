//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import UIKit
import AVFoundation
import Photos

enum PreparedAttachmentSourcePersistence {
    /// Persists the prepared file URL on Core Data's single writable context and returns only an
    /// immutable model snapshot. This is safe to call from PhotoKit and file-I/O callbacks.
    static func persist(
        database: DatabaseContainer,
        id: AttachmentId,
        localURL: URL
    ) throws -> AnyMessageAttachment {
        var model: AnyMessageAttachment?
        try database.writeAndWait { session in
            guard let attachment = session.attachment(id: id) else {
                throw ClientError.AttachmentDoesNotExist(id: id)
            }
            attachment.localURL = localURL
            model = attachment.asAnyModel()
        }
        guard let model else {
            throw ClientError.AttachmentDoesNotExist(id: id)
        }
        return model
    }
}

/// Observers the storage for attachments in a `.pendingUpload` state and uploads data from `localURL` to backend.
///
/// Uploading of the attachment has the following phases:
///     1. When an attachment with `pendingUpload` state local state appears in the db,
///     the uploaded enqueues it in the uploading queue.
///     2. When the attachment is being uploaded, its local state reflects the progress `.uploading(progress: [0, 1])`.
///     The message state is also updated so FRC receive message updates when attachments are changed.
///     3. If the operation is successful the local state of the attachment is changed to `.uploaded`.
///     If the operation fails the local state is set to `.uploadedFailed`.
///
// TODO:
/// - Upload attachments in order declared by `locallyCreatedAt`
/// - Start uploading attachments when connection status changes (offline -> online)
///
class AttachmentQueueUploader: Worker {
    @Atomic private var pendingAttachmentIDs: Set<AttachmentId> = []
    @Atomic private var pendingE2eeMessageIDs: Set<MessageId> = []
    @Atomic private var observedE2eeTransferStates: [String: E2eeTransferProgress] = [:]

    private let observer: ListDatabaseObserver<AttachmentDTO, AttachmentDTO>
    private let attachmentPostProcessor: UploadedAttachmentPostProcessor?
    private let attachmentUpdater = AnyAttachmentUpdater()
    private let attachmentStorage = AttachmentStorage()
    private let e2eePreparationCoordinator: E2eeAttachmentPreparationCoordinator?
    private let currentUserId: () -> UserId?
    private var e2eeTransferObserverId: UUID?

    var minSignificantUploadingProgressChange: Double = 0.05

    init(
        database: DatabaseContainer,
        apiClient: APIClient,
        attachmentPostProcessor: UploadedAttachmentPostProcessor?,
        e2eePreparationCoordinator: E2eeAttachmentPreparationCoordinator? = nil,
        currentUserId: @escaping () -> UserId? = { nil }
    ) {
        observer = .init(
            context: database.backgroundReadOnlyContext,
            fetchRequest: AttachmentDTO.pendingUploadFetchRequest(),
            itemCreator: { $0 }
        )
        
        self.attachmentPostProcessor = attachmentPostProcessor
        self.e2eePreparationCoordinator = e2eePreparationCoordinator
        self.currentUserId = currentUserId

        super.init(database: database, apiClient: apiClient)

        startObservingE2eeTransfers()
        startObserving()
    }

    deinit {
        if let e2eeTransferObserverId {
            e2eePreparationCoordinator?.removeTransferObserver(e2eeTransferObserverId)
        }
    }

    // MARK: - Private

    private func startObserving() {
        do {
            try observer.startObserving()
            observer.onChange = { [weak self] in self?.handleChanges(changes: $0) }
            let changes = observer.items.map { ListChange.insert($0, index: .init(item: 0, section: 0)) }
            handleChanges(changes: changes)
        } catch {
            log.error("Failed to start Uploader worker. \(error)")
        }
    }

    private func startObservingE2eeTransfers() {
        e2eeTransferObserverId = e2eePreparationCoordinator?.addTransferObserver { [weak self] attempt in
            self?.applyE2eeTransferSnapshot(attempt)
        }
    }

    private func applyE2eeTransferSnapshot(_ attempt: PendingE2eeTransferAttempt) {
        guard attempt.accountId == currentUserId() else { return }
        let progress = attempt.publicProgress
        var shouldApply = false
        _observedE2eeTransferStates.mutate { [minSignificantUploadingProgressChange] states in
            let previous = states[attempt.attemptId]
            let phaseChanged = previous?.phase != progress.phase
                || previous?.failureReason != progress.failureReason
            let progressChangedEnough = previous == nil
                || progress.fractionCompleted >= 1
                || progress.fractionCompleted - (previous?.fractionCompleted ?? 0)
                    >= minSignificantUploadingProgressChange
            guard phaseChanged || progressChangedEnough else { return }
            states[attempt.attemptId] = progress
            shouldApply = true
        }
        guard shouldApply else { return }

        let isTerminal = attempt.phase == .failedRetryable
            || attempt.phase == .failedTerminal
            || attempt.phase == .canceled
            || attempt.phase == .confirmed
        if isTerminal {
            _pendingE2eeMessageIDs.mutate { $0.remove(attempt.messageId) }
        } else {
            _pendingE2eeMessageIDs.mutate { $0.insert(attempt.messageId) }
        }

        let visibleProgress = progress.presentationFractionCompleted
        let percent = Int((visibleProgress * 100).rounded(.down))
        log.info("[E2EE_ATTACHMENT] stage=state phase=\(attempt.phase.rawValue) visible_progress=\(percent)")
        database.write { [minSignificantUploadingProgressChange] session in
            guard let message = session.message(id: attempt.messageId) else { return }
            switch attempt.phase {
            case .failedRetryable, .failedTerminal, .canceled:
                message.localMessageState = .sendingFailed
                message.attachments.forEach { $0.localState = .uploadingFailed }
            case .confirmed:
                message.attachments.forEach { $0.localState = .uploaded }
            default:
                for attachment in message.attachments {
                    let currentProgress: Double
                    if case let .uploading(value) = attachment.localState {
                        currentProgress = value
                    } else {
                        currentProgress = 0
                    }
                    let newProgress = max(currentProgress, visibleProgress)
                    let shouldPersist = newProgress >= 1
                        || newProgress - currentProgress >= minSignificantUploadingProgressChange
                        || attachment.localState != .uploading(progress: currentProgress)
                    if shouldPersist {
                        attachment.localState = .uploading(progress: newProgress)
                    }
                }
            }
        }
    }

    private func handleChanges(changes: [ListChange<AttachmentDTO>]) {
        guard !changes.isEmpty else { return }

        // Only start uploading attachment when inserted and it is present in pendingAttachmentIds
        database.backgroundReadOnlyContext.perform { [weak self] in
            self?._pendingAttachmentIDs.mutate { pendingAttachmentIDs in
                let newAttachmentIds = Set(changes.attachmentIDs).subtracting(pendingAttachmentIDs)
                newAttachmentIds.forEach {
                    pendingAttachmentIDs.insert($0)
                }
                newAttachmentIds.forEach { id in
                    self?.uploadAttachment(with: id)
                }
            }
        }
    }

    private func uploadAttachment(with id: AttachmentId) {
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self,
                  let attachment = self.database.backgroundReadOnlyContext.attachment(id: id) else {
                self?.removePendingAttachment(with: id)
                return
            }
            // Never downgrade an attachment to the standard plaintext lane just because its
            // durable channel relationship is temporarily unavailable during reconciliation.
            guard let channel = attachment.message.channel else {
                log.error("[ATTACHMENT_ROUTE] lane=blocked reason=channel_unavailable")
                self.updateAttachmentIfNeeded(
                    attachmentId: id,
                    uploadedAttachment: nil,
                    newState: .uploadingFailed
                ) {
                    self.removePendingAttachment(with: id)
                }
                return
            }
            if channel.isE2eeEnabled {
                log.debug("[ATTACHMENT_ROUTE] lane=e2ee")
                if let accountId = self.currentUserId(),
                   let coordinator = self.e2eePreparationCoordinator,
                   coordinator.hasDurableAttempt(
                       messageId: id.messageId,
                       accountId: accountId
                   ) {
                    // MessageSender resets in-progress attachment rows to `pendingUpload` after a
                    // process death. A durable E2EE attempt is authoritative here: replay its
                    // phase and reconcile URLSession instead of reading an expired Photos picker
                    // URL or creating a duplicate Bellboy attachment attempt.
                    log.info(
                        "[E2EE_ATTACHMENT] stage=relaunch_resume state=durable_attempt_found"
                    )
                    self.removePendingAttachment(with: id)
                    coordinator.replayAndResumeDurableTransfers()
                    return
                }
                self.prepareE2eeAttachmentSource(with: id)
            } else {
                log.debug("[ATTACHMENT_ROUTE] lane=standard")
                self.uploadStandardAttachment(with: id)
            }
        }
    }

    private func uploadStandardAttachment(with id: AttachmentId) {
        prepareAttachmentForUpload(with: id) { [weak self] attachment, error in
            guard error == nil else {
                log.error("Attachment source preparation failed before standard upload: \(String(describing: error))")
                self?.updateAttachmentIfNeeded(attachmentId: id, uploadedAttachment: nil, newState: .uploadingFailed)
                return
            }
            guard let attachment = attachment else {
                self?.removePendingAttachment(with: id)
                return
            }

            self?.apiClient.uploadAttachment(
                attachment,
                progress: {
                    self?.updateAttachmentIfNeeded(
                        attachmentId: id,
                        uploadedAttachment: nil,
                        newState: .uploading(progress: $0),
                        completion: {}
                    )
                },
                completion: { result in
                    // If attachment type video, manual upload thumbnail and replace content with new thumbnail url
                    if attachment.type == .video,
                       var uploadedAttachment = result.value {
                        self?.uploadVideoThumbnail(of: attachment, completion: { [weak self] result in
                            if let uploadedThumbnailAttachment = result.value {
                                uploadedAttachment = UploadedAttachment(attachment: uploadedAttachment.attachment,
                                                                        remoteURL: uploadedAttachment.remoteURL,
                                                                        thumbnailURL: uploadedThumbnailAttachment.remoteURL)
                            }
                            self?.updateAttachmentIfNeeded(
                                attachmentId: id,
                                uploadedAttachment: uploadedAttachment,
                                newState: .uploaded,
                                completion: {
                                    self?.removePendingAttachment(with: id)
                                }
                            )
                        })
                    } else {
                        self?.updateAttachmentIfNeeded(
                            attachmentId: id,
                            uploadedAttachment: result.value,
                            newState: result.error == nil ? .uploaded : .uploadingFailed,
                            completion: {
                                self?.removePendingAttachment(with: id)
                            }
                        )
                    }
                }
            )
        }
    }

    /// E2EE must fail closed: this path materializes the Photos/item-provider URL but never calls
    /// the legacy plaintext upload endpoint.
    private func prepareE2eeAttachmentSource(with id: AttachmentId) {
        guard e2eePreparationCoordinator != nil else {
            log.error("[E2EE_ATTACHMENT] stage=route_failed reason=coordinator_unavailable")
            updateAttachmentIfNeeded(
                attachmentId: id,
                uploadedAttachment: nil,
                newState: .uploadingFailed
            )
            removePendingAttachment(with: id)
            return
        }

        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self,
                  let dto = self.database.backgroundReadOnlyContext.attachment(id: id),
                  let sourceURL = dto.localURL else {
                self?.failE2eeAttachment(id, stage: "source_lookup", error: ClientError.AttachmentDoesNotExist(id: id))
                return
            }
            let assetId = dto.assetId
            let attachmentType = dto.attachmentType
            let destination = self.attachmentStorage.sandboxedURL(for: id, temporaryURL: sourceURL)
            if self.attachmentStorage.fileExists(at: destination) {
                self.persistPreparedE2eeSource(id: id, localURL: destination)
                return
            }

            if sourceURL.isTemporaryItemProviderURL, let assetId {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
                guard let asset = result.firstObject,
                      let resource = Self.preferredResource(for: asset) else {
                    self.failE2eeAttachment(
                        id,
                        stage: "photos_resolve",
                        error: ClientError.AttachmentDoesNotExist(id: id)
                    )
                    return
                }
                if attachmentType == .image {
                    self.materializeE2eePhotoAsset(
                        asset,
                        id: id,
                        destination: destination
                    )
                    return
                }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                let partialURL = self.attachmentStorage.partialURL(for: destination)
                try? FileManager.default.removeItem(at: partialURL)
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: partialURL,
                    options: options
                ) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        try? FileManager.default.removeItem(at: partialURL)
                        self.failE2eeAttachment(id, stage: "photos_copy", error: error)
                    } else {
                        do {
                            try self.attachmentStorage.promotePreparedSource(
                                partialURL,
                                to: destination
                            )
                            self.persistPreparedE2eeSource(id: id, localURL: destination)
                        } catch {
                            try? FileManager.default.removeItem(at: partialURL)
                            self.failE2eeAttachment(id, stage: "photos_promote", error: error)
                        }
                    }
                }
                return
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                do {
                    try self.attachmentStorage.storeAttachmentPreservingOriginal(
                        id: id,
                        temporaryURL: sourceURL
                    )
                    self.persistPreparedE2eeSource(id: id, localURL: destination)
                } catch {
                    self.failE2eeAttachment(id, stage: "source_copy", error: error)
                }
            }
        }
    }

    /// PhotoKit may expose the original HEIC/HEIF resource even when the composer metadata says
    /// `image/jpeg`. Encrypting those raw bytes under a JPEG manifest makes the preview readable
    /// but the original undecodable by Web and iOS viewers. The plaintext "original" for this
    /// message is therefore materialized as an actual JPEG before E2EE framing.
    private func materializeE2eePhotoAsset(
        _ asset: PHAsset,
        id: AttachmentId,
        destination: URL
    ) {
        let partialURL = attachmentStorage.partialURL(for: destination)
        try? FileManager.default.removeItem(at: partialURL)

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, _ in
            guard let self else { return }
            do {
                guard let jpegData = image?.jpegData(compressionQuality: 0.92) else {
                    throw ClientError.AttachmentDoesNotExist(id: id)
                }
                try jpegData.write(to: partialURL, options: .atomic)
                try self.attachmentStorage.promotePreparedSource(partialURL, to: destination)
                self.persistPreparedE2eeSource(id: id, localURL: destination)
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                self.failE2eeAttachment(id, stage: "photos_image_materialize", error: error)
            }
        }
    }

    private func persistPreparedE2eeSource(id: AttachmentId, localURL: URL) {
        database.write({ session in
            guard let attachment = session.attachment(id: id) else {
                throw ClientError.AttachmentDoesNotExist(id: id)
            }
            attachment.localURL = localURL
            attachment.localState = .uploading(progress: 0)
        }, completion: { [weak self] error in
            guard let self else { return }
            if let error {
                self.failE2eeAttachment(id, stage: "source_persist", error: error)
                return
            }
            self.removePendingAttachment(with: id)
            self.startE2eeMessageIfReady(messageId: id.messageId)
        })
    }

    private struct E2eePendingMessageSnapshot {
        let messageId: MessageId
        let cid: String
        let attachments: [AnyMessageAttachment]
    }

    private func startE2eeMessageIfReady(messageId: MessageId) {
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self,
                  let message = self.database.backgroundReadOnlyContext.message(id: messageId),
                  let cid = message.cid,
                  message.channel?.isE2eeEnabled == true else { return }
            let ordered = message.attachments.sorted {
                ($0.attachmentID?.rawValue ?? "") < ($1.attachmentID?.rawValue ?? "")
            }
            let models = ordered.compactMap { $0.asAnyModel() }
            guard !ordered.isEmpty,
                  ordered.allSatisfy({ $0.localState == .uploading(progress: 0) }),
                  models.count == ordered.count else { return }
            var shouldStart = false
            self._pendingE2eeMessageIDs.mutate {
                shouldStart = $0.insert(messageId).inserted
            }
            guard shouldStart else { return }
            self.startE2eePreparation(
                E2eePendingMessageSnapshot(
                    messageId: messageId,
                    cid: cid,
                    attachments: models
                )
            )
        }
    }

    private func startE2eePreparation(_ snapshot: E2eePendingMessageSnapshot) {
        guard let accountId = currentUserId(),
              let coordinator = e2eePreparationCoordinator else {
            failE2eeMessage(
                messageId: snapshot.messageId,
                stage: "preflight",
                error: ClientError.CurrentUserDoesNotExist()
            )
            return
        }
        let inputs = snapshot.attachments.compactMap(Self.e2eePreparationInput)
        guard inputs.count == snapshot.attachments.count else {
            failE2eeMessage(
                messageId: snapshot.messageId,
                stage: "metadata",
                error: E2eeAttachmentPreparationError.sourceUnavailable
            )
            return
        }
        log.info("[E2EE_ATTACHMENT] stage=preparing count=\(inputs.count)")
        coordinator.prepareAndSchedule(
            accountId: accountId,
            messageId: snapshot.messageId,
            cid: snapshot.cid,
            attachments: inputs
        ) { [weak self] result in
            switch result {
            case .success:
                log.info("[E2EE_ATTACHMENT] stage=background_upload_scheduled count=\(inputs.count)")
            case .failure(let error):
                self?.failE2eeMessage(
                    messageId: snapshot.messageId,
                    stage: "prepare_or_schedule",
                    error: error
                )
            }
        }
    }

    private static func e2eePreparationInput(
        _ attachment: AnyMessageAttachment
    ) -> E2eeAttachmentPreparationInput? {
        guard let uploading = attachment.uploadingState else { return nil }
        var display: [String: RawJSON] = [
            "size": .number(Double(uploading.file.size))
        ]
        if let title = attachment.title { display["name"] = .string(title) }
        if let mimeType = attachment.mimetype { display["mime_type"] = .string(mimeType) }
        if let image = attachment.attachment(payloadType: ImageAttachmentPayload.self) {
            if let width = image.originalWidth { display["width"] = .number(width) }
            if let height = image.originalHeight { display["height"] = .number(height) }
        } else if let video = attachment.attachment(payloadType: VideoAttachmentPayload.self),
                  let duration = video.duration {
            display["duration"] = .number(duration)
        } else if let voice = attachment.attachment(payloadType: VoiceRecordingAttachmentPayload.self),
                  let duration = voice.duration {
            display["duration"] = .number(duration)
        }
        return E2eeAttachmentPreparationInput(
            sourceURL: uploading.localFileURL,
            title: attachment.title,
            mimeType: attachment.mimetype,
            display: display,
            generatesImagePreview: attachment.type == .image,
            generatesVideoPreview: attachment.type == .video,
            videoDuration: attachment.attachment(payloadType: VideoAttachmentPayload.self)?.duration
        )
    }

    /// A Live Photo or edited asset can expose several resources. E2EE must stage media bytes,
    /// never an adjustment sidecar or paired resource selected only by array position.
    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType]
        switch asset.mediaType {
        case .image:
            preferredTypes = [.photo, .fullSizePhoto, .alternatePhoto]
        case .video:
            preferredTypes = [.video, .fullSizeVideo]
        default:
            preferredTypes = []
        }
        for type in preferredTypes {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }
        return resources.first(where: {
            $0.type != .adjustmentData && $0.type != .pairedVideo
        })
    }

    private func failE2eeAttachment(_ id: AttachmentId, stage: String, error: Error) {
        log.error("[E2EE_ATTACHMENT] stage=\(stage) result=failed error=\(type(of: error))")
        updateAttachmentIfNeeded(
            attachmentId: id,
            uploadedAttachment: nil,
            newState: .uploadingFailed
        ) {
            self.removePendingAttachment(with: id)
        }
    }

    private func failE2eeMessage(messageId: MessageId, stage: String, error: Error) {
        log.error("[E2EE_ATTACHMENT] stage=\(stage) result=failed error=\(type(of: error))")
        database.write({ session in
            guard let message = session.message(id: messageId) else { return }
            message.localMessageState = .sendingFailed
            message.attachments.forEach { $0.localState = .uploadingFailed }
        }, completion: { [weak self] _ in
            self?._pendingE2eeMessageIDs.mutate { $0.remove(messageId) }
        })
    }

    private func uploadVideoThumbnail(of videoAttachment: AnyMessageAttachment,
                                      completion: @escaping (Result<UploadedAttachment, Error>) -> Void) {
        let commonError = NSError(domain: "Upload video thumbnail failed", code: 999)
        guard let localVideoUrl = videoAttachment.uploadingState?.localFileURL else {
            completion(.failure(commonError))
            return
        }

        self.generateThumbnailForAsset(with: localVideoUrl) { [weak self] result in
            switch result {
            case .success(let thumbnailImage):
                guard let url = try? self?.temporaryLocalFileUrl(of: thumbnailImage),
                      let attachmentFile = try? AttachmentFile(url: url, fileSize: nil) else {
                    completion(.failure(commonError))
                    return
                }

                let thumbnailAttachment = AnyMessageAttachment(id: videoAttachment.id,
                                                               type: .image,
                                                               payload: .init(),
                                                               thumbnailData: nil,
                                                               uploadingState: .init(localFileURL: url,
                                                                                     state: .pendingUpload,
                                                                                     file: attachmentFile))
                self?.apiClient.uploadVideoThumbnail(attachment: thumbnailAttachment, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func prepareAttachmentForUpload(with id: AttachmentId, completion: @escaping (AnyMessageAttachment?, Error?) -> Void) {
        database.backgroundReadOnlyContext.perform { [weak self] in
            guard let self,
                  let attachment = self.database.backgroundReadOnlyContext.attachment(id: id),
                  let sourceURL = attachment.localURL else {
                self?.finishStandardSourcePreparation(
                    completion: completion,
                    model: nil,
                    error: ClientError.AttachmentDoesNotExist(id: id)
                )
                return
            }

            // Snapshot only immutable values. A managed `AttachmentDTO` must never escape this
            // context into a PhotoKit callback or a file-I/O queue.
            let assetId = attachment.assetId
            let attachmentType = attachment.attachmentType
            let destination = self.attachmentStorage.sandboxedURL(
                for: id,
                temporaryURL: sourceURL
            )

            if self.attachmentStorage.fileExists(at: destination) {
                self.persistPreparedStandardSource(
                    id: id,
                    localURL: destination,
                    completion: completion
                )
                return
            }

            if sourceURL.isTemporaryItemProviderURL, let assetId {
                let fetchResult = PHAsset.fetchAssets(
                    withLocalIdentifiers: [assetId],
                    options: nil
                )
                guard let asset = fetchResult.firstObject,
                      let resource = Self.preferredResource(for: asset) else {
                    log.error("Asset does not exist", subsystems: .offlineSupport)
                    self.finishStandardSourcePreparation(
                        completion: completion,
                        model: nil,
                        error: ClientError.AttachmentDoesNotExist(id: id)
                    )
                    return
                }
                self.materializeStandardPhotoAsset(
                    asset,
                    resource: resource,
                    id: id,
                    destination: destination,
                    completion: completion
                )
                return
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                do {
                    let localURL: URL
                    if attachmentType == .image {
                        localURL = try self.attachmentStorage.storeAttachment(
                            id: id,
                            temporaryURL: sourceURL
                        )
                    } else {
                        localURL = try self.attachmentStorage.storeAttachmentPreservingOriginal(
                            id: id,
                            temporaryURL: sourceURL
                        )
                    }
                    self.persistPreparedStandardSource(
                        id: id,
                        localURL: localURL,
                        completion: completion
                    )
                } catch {
                    log.error(
                        "Could not copy attachment to local storage: \(error.localizedDescription)",
                        subsystems: .offlineSupport
                    )
                    self.finishStandardSourcePreparation(
                        completion: completion,
                        model: nil,
                        error: ClientError.AttachmentDoesNotExist(id: id)
                    )
                }
            }
        }
    }

    private func materializeStandardPhotoAsset(
        _ asset: PHAsset,
        resource: PHAssetResource,
        id: AttachmentId,
        destination: URL,
        completion: @escaping (AnyMessageAttachment?, Error?) -> Void
    ) {
        let partialURL = attachmentStorage.partialURL(for: destination)
        try? FileManager.default.removeItem(at: partialURL)

        if asset.mediaType == .image {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, _ in
                guard let self else { return }
                do {
                    guard let imageData = image?.jpegData(compressionQuality: 0.5) else {
                        throw ClientError.AttachmentDoesNotExist(id: id)
                    }
                    try imageData.write(to: partialURL, options: .atomic)
                    try self.attachmentStorage.promotePreparedSource(
                        partialURL,
                        to: destination
                    )
                    self.persistPreparedStandardSource(
                        id: id,
                        localURL: destination,
                        completion: completion
                    )
                } catch {
                    try? FileManager.default.removeItem(at: partialURL)
                    self.finishStandardSourcePreparation(
                        completion: completion,
                        model: nil,
                        error: error
                    )
                }
            }
            return
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: partialURL,
            options: options
        ) { [weak self] error in
            guard let self else { return }
            do {
                if let error { throw error }
                try self.attachmentStorage.promotePreparedSource(
                    partialURL,
                    to: destination
                )
                self.persistPreparedStandardSource(
                    id: id,
                    localURL: destination,
                    completion: completion
                )
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                log.error("Photo asset copy failed: \(error.localizedDescription)", subsystems: .offlineSupport)
                self.finishStandardSourcePreparation(
                    completion: completion,
                    model: nil,
                    error: error
                )
            }
        }
    }

    private func persistPreparedStandardSource(
        id: AttachmentId,
        localURL: URL,
        completion: @escaping (AnyMessageAttachment?, Error?) -> Void
    ) {
        do {
            let model = try PreparedAttachmentSourcePersistence.persist(
                database: database,
                id: id,
                localURL: localURL
            )
            finishStandardSourcePreparation(
                completion: completion,
                model: model,
                error: nil
            )
        } catch {
            finishStandardSourcePreparation(
                completion: completion,
                model: nil,
                error: error
            )
        }
    }

    private func finishStandardSourcePreparation(
        completion: @escaping (AnyMessageAttachment?, Error?) -> Void,
        model: AnyMessageAttachment?,
        error: Error?
    ) {
        DispatchQueue.main.async {
            completion(model, error)
        }
    }

    private func removePendingAttachment(with id: AttachmentId) {
        _pendingAttachmentIDs.mutate { $0.remove(id) }
    }

    private func updateAttachmentIfNeeded(
        attachmentId: AttachmentId,
        uploadedAttachment: UploadedAttachment?,
        newState: LocalAttachmentState,
        completion: @escaping () -> Void = {}
    ) {
        database.write({ [minSignificantUploadingProgressChange, weak self] session in
            guard let attachmentDTO = session.attachment(id: attachmentId) else { return }

            var stateHasChanged: Bool {
                guard
                    case let .uploading(lastProgress) = attachmentDTO.localState,
                    case let .uploading(currentProgress) = newState
                else {
                    return attachmentDTO.localState != newState
                }

                return (currentProgress - lastProgress) >= minSignificantUploadingProgressChange
            }

            guard stateHasChanged else { return }

            // Update attachment local state.
            attachmentDTO.localState = newState

            let message = attachmentDTO.message

            // When all attachments finish uploading, mark message pending send
            if newState == .uploaded {
                let allAttachmentsAreUploaded = message.attachments.filter { $0.localState != .uploaded }.isEmpty
                // We only want to make a message to be resent when it is in failed state
                // If we did not check the state, when editing a message, it would resend an existing message
                if allAttachmentsAreUploaded && message.localMessageState == .sendingFailed {
                    message.localMessageState = .pendingSend
                }
            }
            
            // If attachment failed upload, mark message as failed
            if newState == .uploadingFailed {
                message.localMessageState = .sendingFailed
            }

            if var uploadedAttachment = uploadedAttachment {
                self?.updateRemoteUrl(of: &uploadedAttachment)
                if let processedAttachment = self?.attachmentPostProcessor?.process(uploadedAttachment: uploadedAttachment) {
                    uploadedAttachment = processedAttachment
                }
                attachmentDTO.data = uploadedAttachment.attachment.payload
                self?.removeDataFromLocalStorage(for: attachmentId)
            }
        }, completion: {
            if let error = $0 {
                log.error("Error changing localState for attachment with id \(attachmentId) to `\(newState)`: \(error)")
            }
            completion()
        })
    }

    /// Update the remote url for each attachment payload type. Every other payload
    /// update should be handled by the ``Uploader``.
    private func updateRemoteUrl(of uploadedAttachment: inout UploadedAttachment) {
        var attachment = uploadedAttachment.attachment

        attachmentUpdater.update(&attachment, forPayload: ImageAttachmentPayload.self) { payload in
            payload.imageURL = uploadedAttachment.remoteURL
        }

        attachmentUpdater.update(&attachment, forPayload: VideoAttachmentPayload.self) { payload in
            payload.videoURL = uploadedAttachment.remoteURL
            payload.thumbnailURL = uploadedAttachment.thumbnailURL
        }

        attachmentUpdater.update(&attachment, forPayload: AudioAttachmentPayload.self) { payload in
            payload.audioURL = uploadedAttachment.remoteURL
        }

        attachmentUpdater.update(&attachment, forPayload: FileAttachmentPayload.self) { payload in
            payload.assetURL = uploadedAttachment.remoteURL
        }

        attachmentUpdater.update(&attachment, forPayload: VoiceRecordingAttachmentPayload.self) { payload in
            payload.voiceRecordingURL = uploadedAttachment.remoteURL
        }

        uploadedAttachment.attachment = attachment
    }

    private func removeDataFromLocalStorage(for attachmentId: AttachmentId) {
        database.write { [weak attachmentStorage] session in
            guard let attachmentLocalURL = session.attachment(id: attachmentId)?.localURL else { return }
            attachmentStorage?.removeAttachment(at: attachmentLocalURL)
        }
    }

    // Video thumb helper
    private func generateThumbnailForAsset(with url: URL, completion: @escaping (Result<UIImage, Error>) -> Void) {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        let frameTime = CMTime(seconds: 0.1, preferredTimescale: 600)

        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.generateCGImagesAsynchronously(forTimes: [.init(time: frameTime)]) { _, image, _, _, error in
            let result: Result<UIImage, Error>
            if let thumbnail = image {
                result = .success(.init(cgImage: thumbnail))
            } else if let thumbnail = UIImage(systemName: "questionmark.video") {
                // place default thumbnail
                result = .success(thumbnail)
            } else {
                result = .failure(ClientError("Failed to generate thumbnail"))
            }
            completion(result)
        }
    }

    private func temporaryLocalFileUrl(of image: UIImage) throws -> URL? {
        guard let imageData = image.jpegData(compressionQuality: 1.0) else { return nil }
        let imageName = "\(UUID().uuidString).jpg"
        let documentDirectory = NSTemporaryDirectory()
        let localPath = documentDirectory.appending(imageName)
        let photoURL = URL(fileURLWithPath: localPath)
        try imageData.write(to: photoURL)
        return photoURL
    }
}

private extension Array where Element == ListChange<AttachmentDTO> {
    var attachmentIDs: [AttachmentId] {
        compactMap {
            switch $0 {
            case let .insert(dto, _), let .update(dto, _):
                return dto.attachmentID
            case .move, .remove:
                return nil
            }
        }
    }
}

private class AttachmentStorage {
    enum Constants {
        static let path = "LocalAttachments"
    }

    private let fileManager: FileManager
    private lazy var baseURL: URL = {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent(Constants.path)
    }()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            log.error("Could not create a directory to store attachments: \(error.localizedDescription)")
        }
    }

    /// Since iOS 8, we cannot use absolute paths to access resources because the intermediate folders can change between sessions/app runs. The content of it, when
    /// using `.documentsDirectory`, is stable though.
    /// Because of that, if the file is already in our storage, the only thing we will do is to return a fresh and valid url to access it.
    func storeAttachment(id: AttachmentId, temporaryURL: URL) throws -> URL {
        let sandboxedURL = sandboxedURL(for: id, temporaryURL: temporaryURL)

        // If the attachment is already sandboxed, return it.
        if fileExists(at: sandboxedURL) {
            return sandboxedURL
        }

        if let type = try? temporaryURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .heic), let data = try? Data(contentsOf: temporaryURL),
           let image = UIImage(data: data),
           let jpegData = image.jpegData(compressionQuality: 1.0) {
            try jpegData.write(to: sandboxedURL)
        } else {
            try Data(contentsOf: temporaryURL).write(to: sandboxedURL)
        }
        return sandboxedURL
    }

    /// E2EE source material must retain the original bytes and must not be loaded as one `Data`.
    /// Photos assets use `PHAssetResourceManager`; file/item-provider inputs use this streaming
    /// filesystem copy before the temporary provider URL can disappear.
    @discardableResult
    func storeAttachmentPreservingOriginal(id: AttachmentId, temporaryURL: URL) throws -> URL {
        let destination = sandboxedURL(for: id, temporaryURL: temporaryURL)
        if fileExists(at: destination) { return destination }
        let partial = partialURL(for: destination)
        try? fileManager.removeItem(at: partial)
        do {
            try fileManager.copyItem(at: temporaryURL, to: partial)
            try promotePreparedSource(partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        return destination
    }

    func partialURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".partial")
    }

    func promotePreparedSource(_ partial: URL, to destination: URL) throws {
        if fileExists(at: destination) {
            try? fileManager.removeItem(at: partial)
            return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutablePartial = partial
        try mutablePartial.setResourceValues(values)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: partial.path
        )
#endif
        try fileManager.moveItem(at: partial, to: destination)
    }

    func sandboxedURL(for id: AttachmentId, temporaryURL: URL) -> URL {
        // The file name should be composed by the id of the attachment so that it is unique.
        let fileExtension = temporaryURL.pathExtension
        let attachmentId = [id.cid.rawValue, id.messageId, String(id.index)].joined(separator: "-")
        let fileId = "\(attachmentId).\(fileExtension)"
        let sandboxedURL = baseURL.appendingPathComponent(fileId)
        return sandboxedURL
    }

    func removeAttachment(at localURL: URL) {
        guard fileExists(at: localURL) else { return }
        do {
            try fileManager.removeItem(at: localURL)
        } catch {
            log.info("Unable to remove attachment at \(localURL): \(error.localizedDescription)")
        }
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}
