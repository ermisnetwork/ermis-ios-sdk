//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button used for sending a message, or any type of content.
open class SendButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let normalStateImage = theme.icons.send
        setImage(normalStateImage, for: .normal)

        let buttonColor: UIColor = theme.colors.surfaceContainerHighest
        let disabledStateImage = theme.icons.send.tinted(with: buttonColor)
        setImage(disabledStateImage, for: .disabled)
    }
}
