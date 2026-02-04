//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Data {
    func toString() -> String {
        return self.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

