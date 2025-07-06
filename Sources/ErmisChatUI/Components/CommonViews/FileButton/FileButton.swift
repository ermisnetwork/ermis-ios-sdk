//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for opening attachments.
open class FileButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let clipIcon = theme
            .icons
            .openAttachments
            .tinted(with: theme.colors.text)
        setImage(clipIcon, for: .normal)
    }
}
