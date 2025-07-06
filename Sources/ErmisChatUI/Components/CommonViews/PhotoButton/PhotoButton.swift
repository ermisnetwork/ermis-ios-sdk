//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for opening attachments.
open class PhotoButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let clipIcon = theme
            .icons
            .photo
            .tinted(with: theme.colors.text)
        setImage(clipIcon, for: .normal)
    }
}
