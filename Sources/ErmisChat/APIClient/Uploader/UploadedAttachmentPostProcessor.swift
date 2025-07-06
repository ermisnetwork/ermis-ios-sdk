//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A component that used to modify an attachment which was successfully uploaded.
public protocol UploadedAttachmentPostProcessor {
    func process(uploadedAttachment: UploadedAttachment) -> UploadedAttachment
}
