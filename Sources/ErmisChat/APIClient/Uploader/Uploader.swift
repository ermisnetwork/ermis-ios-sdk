//
// Copyright 2025 Ermis Inc.
//

import Foundation
/// The protocol responsible to upload files.
public protocol Uploader {
    /// Uploads a type-erased message attachment.
    /// - Parameters:
    ///   - attachment: A type-erased message attachment.
    ///   - progress: The upload progress.
    ///   - completion: The callback with the uploaded attachment.
    func upload(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedAttachment, Error>) -> Void
    )

    /// Uploads user avatar, and returns the avatarPayload.
    /// - Parameters:
    ///   - data: Data of avatar image.
    ///   - progress: The upload progress.
    ///   - completion: The callback with the uploaded avatar attachment.
    func uploadUserAvatar(
        _ data: Data,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void
    )
}

public class ErmisUploader: Uploader {
    let uploadClient: UploadClient

    init(uploadClient: UploadClient) {
        self.uploadClient = uploadClient
    }

    public func upload(
        _ attachment: AnyMessageAttachment,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<UploadedAttachment, Error>) -> Void
    ) {
        uploadClient.uploadAttachment(attachment, progress: progress) { (result: Result<UploadedFile, Error>) in
            completion(result.map { file in
                let uploadedAttachment = UploadedAttachment(
                    attachment: attachment,
                    remoteURL: file.fileURL,
                    thumbnailURL: file.thumbnailURL
                )
                return uploadedAttachment
            })
        }
    }

    public func uploadUserAvatar(
        _ data: Data,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<AvatarUploadPayload, Error>) -> Void) {
            uploadClient.uploadUserAvatar(data, progress: progress, completion: completion)
        }
}
