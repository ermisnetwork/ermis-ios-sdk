//
// Copyright 2025 Ermis Inc.
//

import Foundation

private class BundleIdentifyingClass {}

extension Bundle {
    public static var ermisChatUI: Bundle {
        return Bundle.module
    }
}
