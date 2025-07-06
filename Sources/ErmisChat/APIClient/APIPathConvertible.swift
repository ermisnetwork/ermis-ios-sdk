//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Protocol representing path on API
protocol APIPathConvertible {
    /// Build APi path representing `self`
    var apiPath: String { get }
}
