//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for opening commands.
open class CommandButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let boltIcon = theme
            .icons
            .commands
            .tinted(with: theme.colors.disabledColorForColor(
                theme.colors.text
            ))
        setImage(boltIcon, for: .normal)
    }
}
