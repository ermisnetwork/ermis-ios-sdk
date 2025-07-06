//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The attachment which was successfully uploaded.
public struct UploadedAttachment {
    /// The attachment which contains the payload details of the attachment.
    public var attachment: AnyMessageAttachment

    /// The file remote url.
    public let remoteURL: URL

    /// The thumbnail url.
    public let thumbnailURL: URL?

    public init(
        attachment: AnyMessageAttachment,
        remoteURL: URL,
        thumbnailURL: URL? = nil
    ) {
        self.attachment = attachment
        self.remoteURL = remoteURL
        self.thumbnailURL = thumbnailURL
    }
}
