//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

// MARK: - Protocol

public protocol ThemeProvider: AnyObject {
    /// Theme object to change theme of the existing views or to use default theme of the SDK by custom components.
    var theme: Theme { get }
}

// MARK: - Protocol extensions for UIView

public extension ThemeProvider {
    var theme: Theme {
        Theme.default
    }
}
