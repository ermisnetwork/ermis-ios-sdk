//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for confirming actions.
open class ConfirmButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let normalStateImage = theme.icons.confirmCheckmark
        setImage(normalStateImage, for: .normal)

        let disabledStateImage = theme.icons.confirmCheckmark.tinted(
            with: theme.colors.disabledColorForColor(
                theme.colors.text
            )
        )
        setImage(disabledStateImage, for: .disabled)
    }
}
