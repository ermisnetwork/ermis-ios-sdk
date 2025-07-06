//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays an error indicator inside the message content view.
open class MessageErrorIndicator: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        setImage(theme.icons.messageListErrorIndicator, for: .normal)
        tintColor = theme.colors.error
    }
}
