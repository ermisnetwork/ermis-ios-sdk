//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

// MARK: - Protocol

public protocol FormattersProvider: AnyObject {
    /// Formatters object to change formatters of the existing views or to use default formatters of the SDK by custom components.
    var formatters: Formatters { get }
}

// MARK: - Protocol extensions for UIView

public extension FormattersProvider where Self: UIResponder {
    func formattersDidRegister() {}

    var formatters: Formatters {
        return Formatters.default
    }
}
