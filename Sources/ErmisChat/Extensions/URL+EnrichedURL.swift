//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension URL {
    /// Enriches `URL` with `http` scheme if it's missing
    var enrichedURL: URL {
        guard scheme == nil else {
            return self
        }

        return URL(string: "https://" + absoluteString) ?? self
    }
}
