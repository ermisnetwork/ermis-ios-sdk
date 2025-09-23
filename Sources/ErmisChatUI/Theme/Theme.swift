//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

/// An object containing visual configuration for whole application.

public class Theme {
    /// A color pallete to provide basic set of colors for the Views.
    ///
    /// By providing different object or changing individual colors, you can change the look of the views.
    public var colors = Colors()

    /// A set of fonts to be used in the Views.
    ///
    /// By providing different object or changing individual fonts, you can change the look of the views.
    public var fonts = Fonts()

    /// A set of images to be used.
    ///
    /// By providing different object or changing individual images, you can change the look of the views.
    public var icons = Icons()

    /// Provider for custom localization which is dependent on App Bundle.
    public var localizationProvider: (_ key: String, _ table: String) -> String = { key, table in
        Bundle.ermisChatUI.localizedString(forKey: key, value: nil, table: table)
    }

    public init() {}

    /// Reinit value of Colors, this helpful when we want to modify Colors value with new BaseColor values.
    /// Note: If you want to change Theme Color value directly, not thougt BaseColor value, you must call
    /// after this function
    public func reinitColors() {
        self.colors = Colors()
    }
}


// MARK: - Theme + Default

public extension Theme {
    nonisolated(unsafe) static var `default`: Theme = .init()
}
