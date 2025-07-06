//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChatUI

open class CallTitleContainerView: TitleContainerView {
    public override func setUpTheme() {
        super.setUpTheme()
        titleLabel.textColor = theme.colors.white
        subtitleLabel.textColor = theme.colors.white
    }
}
