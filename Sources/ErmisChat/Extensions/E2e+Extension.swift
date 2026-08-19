//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Data {
    var uint8Array: [UInt8] {
        Array(self)
    }
}

extension [UInt8] {
    var data: Data {
        Data(self)
    }
}
