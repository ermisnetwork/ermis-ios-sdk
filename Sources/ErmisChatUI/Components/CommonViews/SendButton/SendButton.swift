//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button used for sending a message, or any type of content.
open class SendButton: _Button, ThemeProvider {
    /// Override this variable to enable custom behavior upon button enabled.
    override open var isEnabled: Bool {
        didSet {
            isEnabledChangeAnimation(isEnabled)
        }
    }

    override open func setUpTheme() {
        super.setUpTheme()

        let normalStateImage = theme.icons.sendArrow
        setImage(normalStateImage, for: .normal)

        let buttonColor: UIColor = theme.colors.surfaceContainerHighest
        let disabledStateImage = theme.icons.sendArrow.tinted(with: buttonColor)
        setImage(disabledStateImage, for: .disabled)
    }

    /// The animation when the `isEnabled` state changes.
    open func isEnabledChangeAnimation(_ isEnabled: Bool) {
        Animate {
            self.transform = isEnabled
                ? CGAffineTransform(rotationAngle: -CGFloat.pi / 2.0)
                : .identity
        }
    }
}
