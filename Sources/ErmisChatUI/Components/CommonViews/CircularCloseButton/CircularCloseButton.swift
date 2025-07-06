//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for closing, dismissing or clearing information.
open class CircularCloseButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let closeIcon = theme.icons.closeCircleTransparent.tinted(
            with: theme.colors.disabledColorForColor(
                theme.colors.text
            )
        )
        setImage(closeIcon, for: .normal)
    }
}
