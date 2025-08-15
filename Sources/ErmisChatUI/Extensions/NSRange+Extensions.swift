//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension NSRange {
    func merge(with other: NSRange) -> NSRange {
        let start = min(location, other.location)
        let end = max(location + length, other.location + other.length)
        return NSRange(location: start, length: end - start)
    }
}
