//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The cell separator reusable view that acts as container of the visible part of the separator view.
open class CellSeparatorReusableView: _CollectionReusableView, ThemeProvider {
    /// The visible part of separator view.
    open lazy var separatorView = UIView().withoutAutoresizingMaskConstraints

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = .clear
        separatorView.backgroundColor = theme.colors.outline
    }

    override open func setUpUI() {
        embed(separatorView)
    }
}
