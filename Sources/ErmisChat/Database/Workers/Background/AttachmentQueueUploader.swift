//
// Copyright 2025 Ermis Inc.
//

import CoreData
import Foundation
import UIKit
import AVFoundation
import Photos

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

    private let observer: ListDatabaseObserver<AttachmentDTO, AttachmentDTO>
    private let attachmentPostProcessor: UploadedAttachmentPostProcessor?
    private let attachmentUpdater = AnyAttachmentUpdater()
    private let attachmentStorage = AttachmentStorage()

    var minSignificantUploadingProgressChange: Double = 0.05

    init(database: DatabaseContainer, apiClient: APIClient, attachmentPostProcessor: UploadedAttachmentPostProcessor?) {
        observer = .init(
            context: database.backgroundReadOnlyContext,
            fetchRequest: AttachmentDTO.pendingUploadFetchRequest(),
            itemCreator: { $0 }
        )
        
        self.attachmentPostProcessor = attachmentPostProcessor

        super.init(database: database, apiClient: apiClient)

        startObserving()
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
        prepareAttachmentForUpload(with: id) { [weak self] attachment, error in
            guard error == nil else {
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
        let attachmentStorage = self.attachmentStorage
        database.write { session in
            guard let attachment = session.attachment(id: id) else { return }

            let onCompletion: (Error?) -> Void = { error in
                DispatchQueue.main.async {
                    let model = attachment.asAnyModel()
                    completion(attachment.asAnyModel(), error)
                }
            }

            var temporaryURL = attachment.localURL
            /// Check if local url exist, if not, we will fetch from asset id.
            if let temporaryURL, temporaryURL.isTemporaryItemProviderURL, let assetId = attachment.assetId  {

                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
                guard let asset = fetchResult.firstObject, let resource = PHAssetResource.assetResources(for: asset).first else {
                    log.error("Asset not exist", subsystems: .offlineSupport)
                    onCompletion(ClientError.AttachmentDoesNotExist(id: id))
                    return
                }

                let url = attachmentStorage.sandboxedURL(for: id, temporaryURL: temporaryURL)
                if attachmentStorage.fileExists(at: url) {
                    attachment.localURL = url
                    onCompletion(nil)
                    return
                }

                if asset.mediaType == .image {
                    let options = PHImageRequestOptions()
                    options.isSynchronous = true
                    options.deliveryMode = .highQualityFormat
                    options.isNetworkAccessAllowed = true
                    PHImageManager.default().requestImage(for: asset,
                                                          targetSize: PHImageManagerMaximumSize,
                                                          contentMode: .aspectFit,
                                                          options: options) { image, _ in
                        guard let image else {
                            onCompletion(ClientError.AttachmentDoesNotExist(id: id))
                            return
                        }
                        let imageData = image.jpegData(compressionQuality: 0.5)
                        do {
                            try imageData?.write(to: url)
                            attachment.localURL = url
                            onCompletion(nil)
                        } catch {
                            onCompletion(ClientError.Unexpected("Faild to write data to fileURL: \(url)"))
                        }
                    }
                } else {
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true

                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error {
                            log.error("File not exist", subsystems: .offlineSupport)
                            onCompletion(ClientError.AttachmentDoesNotExist(id: id))
                            return
                        } else {
                            attachment.localURL = url
                            onCompletion(nil)
                            return
                        }
                    }
                }

            } else if let temporaryURL = attachment.localURL {
                do {
                    let localURL = try attachmentStorage.storeAttachment(id: id, temporaryURL: temporaryURL)
                    attachment.localURL = localURL
                    onCompletion(nil)
                } catch {
                    log.error("Could not copy attachment to local storage: \(error.localizedDescription)", subsystems: .offlineSupport)
                    onCompletion(ClientError.AttachmentDoesNotExist(id: id))
                }
            }
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
