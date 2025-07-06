//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension UIDevice {
    /// Returns if the device is a Phone
    var isPhone: Bool {
        return userInterfaceIdiom == .phone
    }

    var isPad: Bool {
        return userInterfaceIdiom == .pad && !isMac
    }

    var isMac: Bool {
        return ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac || userInterfaceIdiom == .mac
    }
}


