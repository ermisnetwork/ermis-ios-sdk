//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A file upload response.
struct FileUploadPayload: Decodable {
    let fileURL: URL
    let thumbURL: URL?

    enum CodingKeys: String, CodingKey {
        case fileURL = "file"
        case thumbURL = "thumb_url"
    }
}
