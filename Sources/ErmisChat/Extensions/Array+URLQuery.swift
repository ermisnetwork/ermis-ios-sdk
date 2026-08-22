//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Array where Element == URLQueryItem {
    var prettyPrinted: String {
        isEmpty ? "<Empty>" : "<\(count) query item(s); names and values redacted>"
    }
}
