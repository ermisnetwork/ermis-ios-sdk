//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for opening attachments.
open class StickerButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let stickerIcon = theme
            .icons
            .sticker
            .tinted(with: theme.colors.text)
        setImage(stickerIcon, for: .normal)
    }
}
