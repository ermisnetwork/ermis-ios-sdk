//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for shrinking the input view to allow more space for other actions.
open class ShrinkInputButton: _Button, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()

        let rightArrowIcon = theme.icons.shrinkInputArrow
        setImage(rightArrowIcon, for: .normal)
    }
}
