//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class StickerPackTitleHeaderView: _CollectionReusableView, UIProvider {
    open private(set) lazy var titleLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "titleLabel")

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        embed(titleLabel)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        titleLabel.font = theme.fonts.body.semiBold
        titleLabel.textColor = theme.colors.text
    }
}
