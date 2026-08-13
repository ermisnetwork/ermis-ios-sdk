//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import Photos
/// A class for save donwloaded attachment.
public class AttachmentSaver: NSObject, UIDocumentPickerDelegate {
    let client: ErmisClient
    let presenttingViewController: UIViewController
    let sessionId = UUID().uuidString
    let downloadPath = "downloads"
    let fileManager = FileManager.default
    private weak var verifiedDocumentPicker: UIDocumentPickerViewController?
    private var verifiedDocumentPickerCompletion: ((Error?) -> Void)?

    init(client: ErmisClient, presenttingViewController: UIViewController) {
        self.client = client
        self.presenttingViewController = presenttingViewController
        super.init()
        self.clearOldDownloadedAttachment()
    }

    private let operationQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.save-attachments-queue"
        return operationQueue
    }()

    

    /// Download attachment and save it on device.
    ///
    /// - Parameters:
    ///  - attachements: The list of `AnyMessageAttachment` to download.
    ///  - completion: The closure detemine download progress success or not.
    public func downloadAttachments(attachments: [AnyMessageAttachment], completion: @escaping(Error?) -> Void) {
        let e2eeAttachments = attachments.filter(client.requiresVerifiedE2eeOriginal)
        guard e2eeAttachments.isEmpty else {
            guard e2eeAttachments.count == attachments.count else {
                log.error(
                    "[ATTACHMENT_EXPORT] source=message_action route=rejected_mixed " +
                    "attachment_count=\(attachments.count) e2ee_count=\(e2eeAttachments.count)"
                )
                callback {
                    completion(ClientError.Unexpected("Mixed standard and E2EE attachment export is unsupported."))
                }
                return
            }
            log.info(
                "[ATTACHMENT_EXPORT] source=message_action route=verified_e2ee " +
                "attachment_count=\(e2eeAttachments.count)"
            )
            downloadVerifiedAttachments(e2eeAttachments, completion: completion)
            return
        }

        log.info(
            "[ATTACHMENT_EXPORT] source=message_action route=standard " +
            "attachment_count=\(attachments.count)"
        )
        client.apiClient.downloadMessageAttachments(attachments, progress: nil, completion: { [weak self] result in
            if let error = result.results.first(where: { $0.error != nil})?.error {
                self?.callback {
                    completion(error)
                }
                return
            }
            let downloadedAttachments = result.results.compactMap(\.value)
            self?.saveAttachments(downloadedAttachments, completion: completion)
        })
    }

    /// Saves a local attachment original which has already passed E2EE size/SHA/frame-GCM
    /// verification. This method performs no network access and never accepts an opaque URL.
    public func saveVerifiedAttachment(
        at localURL: URL,
        attachment: AnyMessageAttachment,
        completion: @escaping (Error?) -> Void
    ) {
        saveVerifiedAttachments([(localURL, attachment)], completion: completion)
    }

    private func downloadVerifiedAttachments(
        _ attachments: [AnyMessageAttachment],
        completion: @escaping (Error?) -> Void
    ) {
        _Concurrency.Task { [weak self] in
            guard let self else {
                completion(CancellationError())
                return
            }
            do {
                var resolved: [(URL, AnyMessageAttachment)] = []
                resolved.reserveCapacity(attachments.count)
                // Keep full-original downloads sequential. A message can contain ten assets and
                // each one can approach the 2 GiB cap, so unbounded parallel resolution would
                // amplify disk and network pressure for an explicit "download all" action.
                for attachment in attachments {
                    let localURL = try await client.prepareAttachmentForViewing(attachment)
                    try _Concurrency.Task.checkCancellation()
                    resolved.append((localURL, attachment))
                }
                log.info(
                    "[ATTACHMENT_EXPORT] source=message_action route=verified_e2ee " +
                    "state=resolved attachment_count=\(resolved.count)"
                )
                saveVerifiedAttachments(resolved, completion: completion)
            } catch {
                log.error("[E2EE_ATTACHMENT_EXPORT] state=failed error=\(type(of: error))")
                callback { completion(error) }
            }
        }
    }

    private func saveVerifiedAttachments(
        _ resolved: [(url: URL, attachment: AnyMessageAttachment)],
        completion: @escaping (Error?) -> Void
    ) {
        guard !resolved.isEmpty,
              resolved.allSatisfy({ $0.url.isFileURL && fileManager.fileExists(atPath: $0.url.path) }) else {
            completion(ClientError.Unexpected("Verified attachment file is unavailable."))
            return
        }

        let media = resolved.filter { $0.attachment.type == .image || $0.attachment.type == .video }
        let files = resolved.filter { $0.attachment.type != .image && $0.attachment.type != .video }

        let exportFiles: () -> Void = { [weak self] in
            guard let self else {
                completion(CancellationError())
                return
            }
            guard !files.isEmpty else {
                self.callback { completion(nil) }
                return
            }
            self.presentDocumentPicker(
                urls: files.map(\.url),
                completion: completion
            )
        }

        guard !media.isEmpty else {
            exportFiles()
            return
        }

        requestPhotoLibraryAuthorization { isAuthorized in
            guard isAuthorized else {
                completion(ClientError.PhotoLibraryAuthorization())
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for item in media {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(
                        with: item.attachment.type == .video ? .video : .photo,
                        fileURL: item.url,
                        options: nil
                    )
                }
            }, completionHandler: { _, error in
                guard error == nil else {
                    completion(error)
                    return
                }
                exportFiles()
            })
        }
    }

    private func presentDocumentPicker(
        urls: [URL],
        completion: @escaping (Error?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(CancellationError())
                return
            }
            guard self.verifiedDocumentPickerCompletion == nil else {
                completion(ClientError.Unexpected("An attachment export is already active."))
                return
            }
            let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
            picker.delegate = self
            self.verifiedDocumentPicker = picker
            self.verifiedDocumentPickerCompletion = completion
            log.info(
                "[ATTACHMENT_EXPORT] route=verified_e2ee state=presenting_document_picker " +
                "file_count=\(urls.count)"
            )
            self.presenttingViewController.present(picker, animated: true)
        }
    }

    /// Download channel attachment and save it on device.
    ///
    /// - Parameters:
    ///  - attachement: The list of `ChannelAttachmentPayload` to download.
    ///  - completion: The closure detemine download progress success or not.
    public func downloadChannelAttachment(attachment: ChannelAttachmentPayload, completion: @escaping(Error?) -> Void) {
        client.apiClient.downloadChannelAttachment(attachment, progress: nil, completion: { [weak self] result in
            if let error = result.error {
                self?.callback {
                    completion(error)
                }
                return
            }
            let downloadedAttachments = [result.value].compactMap{$0}
            self?.saveAttachments(downloadedAttachments, completion: completion)
        })
    }

    /// Save downloaded attachment. If attachment is photo or video, it will be
    ///
    /// - Parameters:
    ///   - downloadedAttachments: The `DownloadedAttachment` list to be saved.
    ///  - completion: The closure detemine save progress success or not.
    public func saveAttachments(_ downloadedAttachments: [DownloadedAttachment], completion: @escaping (Error?) -> Void) {
        var firstError: Error?
        let mediaAttachments = downloadedAttachments.filter({ $0.attachment.isImage || $0.attachment.isVideo})
        let fileAttachments = downloadedAttachments.filter({ !$0.attachment.isImage && !$0.attachment.isVideo})
        if !mediaAttachments.isEmpty {
            for mediaAttachment in mediaAttachments {
                let operation = AsyncOperation(maxRetries: 0) { [weak self] operation, done in
                    self?.saveMediaAttachment(mediaAttachment, completion: { [weak self] error in
                        if let error, firstError == nil {
                            firstError = error
                        }
                        if mediaAttachment.attachment.id == mediaAttachments.last?.attachment.id {
                            self?.callback {
                                completion(firstError)
                            }
                        }
                        done(.continue)
                    })
                }
                operationQueue.addOperation(operation)
            }
        }

        if !fileAttachments.isEmpty {
            let operation = AsyncOperation(maxRetries: 0) { [weak self] operation, done in
                self?.saveFileAttachments(fileAttachments, completion: { error in
                    done(.continue)
                })
            }
            operationQueue.addOperation(operation)
        }
    }
    /// Remove old session attachment in document directory.
    func clearOldDownloadedAttachment() {
        var documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        documentDirectory = documentDirectory.appendingPathComponent(downloadPath)
        var removeURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: documentDirectory, includingPropertiesForKeys: nil, options: []) {
            for case let fileURL as URL in enumerator {
                if !fileURL.absoluteString.contains(sessionId) {
                    removeURLs.append(fileURL)
                }
            }
        }
        for removeURL in removeURLs {
            try? FileManager.default.removeItem(at: removeURL)
        }

    }
    /// Save file attachments
    func saveFileAttachments(_ fileAttachments: [DownloadedAttachment],
                             completion: @escaping (Error?) -> Void) {
        do {

            let urls = try fileAttachments.map { try self.documentsDirectory(for: $0)}
            DispatchQueue.main.async {
                let documentPicker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                documentPicker.delegate = self
                self.presenttingViewController.present(documentPicker, animated: true)
            }
        } catch {
            self.callback {
                completion(error)
            }
        }
    }

    func documentsDirectory(for file: DownloadedAttachment) throws -> URL {
        var documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        documentDirectory = documentDirectory.appendingPathComponent("\(downloadPath)/\(sessionId)")
        if !fileManager.fileExists(atPath: documentDirectory.path) {
            try fileManager.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        }
        var fileName = file.attachment.name
        let pathExtension = file.attachment.pathExtension != nil ? ".\(file.attachment.pathExtension!)" : ""
        if fileName.hasSuffix(pathExtension) {
            fileName.removeLast(pathExtension.count)
        }

        var fileURL = documentDirectory.appendingPathComponent(fileName + pathExtension)
        var filePath = fileURL.path
        var postfix = 0

        while fileManager.fileExists(atPath: filePath) {
            postfix += 1
            let newFileName = fileName + "\(postfix)"
            fileURL = documentDirectory.appendingPathComponent(newFileName + pathExtension)
            filePath = fileURL.path
        }

        try file.data.write(to: fileURL)
        return fileURL
    }

    /// Save media attachment.
    func saveMediaAttachment(_ downloadedAttachment: DownloadedAttachment, completion: @escaping (Error?) -> Void) {
        guard downloadedAttachment.attachment.isVideo || downloadedAttachment.attachment.isImage else {
            completion(ClientError.InvalidAttachmentType())
            return
        }
        requestPhotoLibraryAuthorization { [weak self] isSuccess in
            guard isSuccess else {
                completion(ClientError.PhotoLibraryAuthorization())
                return
            }
            PHPhotoLibrary.shared().performChanges ({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: downloadedAttachment.attachment.isVideo ? .video: .photo,
                                    data: downloadedAttachment.data,
                                    options: nil)
            }, completionHandler: { (result, error) in
                completion(error)
            })
        }
    }

    private func requestPhotoLibraryAuthorization(completion: @escaping (Bool) -> Void) {
        let authorizationStatus = PHPhotoLibrary.authorizationStatus()
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            completion(true)
        } else if authorizationStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion(status == .authorized || status == .limited)
                }
            }
        } else {
            completion(false)
        }
    }

    /// A helper function to ensure the callback is performed on the callback queue.
    func callback(_ action: @escaping () -> Void) {
        // We perform the callback synchronously if we're on main & `callbackQueue` is on main, too.
        if Thread.current.isMainThread {
            action()
        } else {
            DispatchQueue.main.async {
                action()
            }
        }
    }

    // MARK: - UIDocumentPickerDelegate
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === verifiedDocumentPicker else { return }
        finishVerifiedDocumentExport(with: CancellationError())
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === verifiedDocumentPicker else { return }
        finishVerifiedDocumentExport(with: nil)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        guard controller === verifiedDocumentPicker else { return }
        finishVerifiedDocumentExport(with: nil)
    }

    private func finishVerifiedDocumentExport(with error: Error?) {
        let completion = verifiedDocumentPickerCompletion
        verifiedDocumentPicker = nil
        verifiedDocumentPickerCompletion = nil
        completion?(error)
    }
}

public extension ClientError {
    final class InvalidAttachmentType: ClientError {}
    final class PhotoLibraryAuthorization: ClientError {}
}

public extension ErmisClient {
    func attachmentSaver(presentingFrom viewController: UIViewController) -> AttachmentSaver {
        return AttachmentSaver(client: self, presenttingViewController: viewController)
    }
}
