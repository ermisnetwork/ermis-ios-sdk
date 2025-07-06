//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

// MARK: - Protocols

public protocol UIProvider: ComponentsProvider, ThemeProvider, FormattersProvider {}

public protocol ComponentsProvider: AnyObject {
    /// Theme object to change components and component types from which the default SDK views are build
    /// or to use the default components in custom views.
    var components: Components { get }
}

// MARK: - Protocol extensions for UIView

public extension ComponentsProvider {
    var components: Components {
        return Components.default
    }
}
