//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
extension String {
    var nsRange: NSRange {
        return NSRange(startIndex..., in: self)
    }

    func range(from nsRange: NSRange) -> Range<String.Index>? {
        return Range(nsRange,  in: self)
    }
}
