//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class ChatNavigationBar: _NavigationBar, ThemeProvider {
    override open func setUpTheme() {
        super.setUpTheme()
        let backIcon = theme.icons.back
        backIndicatorTransitionMaskImage = backIcon
        backIndicatorImage = backIcon
    }
}
