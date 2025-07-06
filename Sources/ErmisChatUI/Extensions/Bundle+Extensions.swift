//
// Copyright 2025 Ermis Inc.
//

import Foundation

private class BundleIdentifyingClass {}

extension Bundle {
    static var ermisChatUI: Bundle {
        return Bundle.module
    }
}
