//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A Button subclass that should be used for download content.
open class DownloadButton: _Button, ThemeProvider {
    override open var isHighlighted: Bool {
        didSet {
            updateContentIfNeeded()
        }
    }

    override open func setUpTheme() {
        super.setUpTheme()

        setImage(theme.icons.download, for: .normal)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        if isHighlighted {
            tintColor = theme.colors.highlightedColorForColor(
                theme.colors.text
            )
        } else {
            tintColor = theme.colors.text
        }
    }
}

