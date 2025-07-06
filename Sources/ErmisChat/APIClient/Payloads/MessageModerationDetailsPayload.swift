//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct MessageModerationDetailsPayload: Decodable {
    let originalText: String
    let action: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case originalText = "original_text"
        case action
    }
}
