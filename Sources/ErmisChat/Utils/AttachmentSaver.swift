//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import Photos
/// A class for save donwloaded attachment.
public class AttachmentSaver: NSObject, UIDocumentPickerDelegate {
    let client: APIClient
    let presenttingViewController: UIViewController
    let sessionId = UUID().uuidString
    let downloadPath = "downloads"
    let fileManager = FileManager.default

    init(client: APIClient, presenttingViewController: UIViewController) {
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
        client.downloadMessageAttachments(attachments, progress: nil, completion: { [weak self] result in
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

    /// Download channel attachment and save it on device.
    ///
    /// - Parameters:
    ///  - attachement: The list of `ChannelAttachmentPayload` to download.
    ///  - completion: The closure detemine download progress success or not.
    public func downloadChannelAttachment(attachment: ChannelAttachmentPayload, completion: @escaping(Error?) -> Void) {
        client.downloadChannelAttachment(attachment, progress: nil, completion: { [weak self] result in
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
        if authorizationStatus == .authorized {
            completion(true)
        } else if authorizationStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion(status == .authorized)
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
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    }
}

public extension ClientError {
    final class InvalidAttachmentType: ClientError {}
    final class PhotoLibraryAuthorization: ClientError {}
}

public extension ErmisClient {
    func attachmentSaver(presentingFrom viewController: UIViewController) -> AttachmentSaver {
        return AttachmentSaver(client: apiClient, presenttingViewController: viewController)
    }
}
