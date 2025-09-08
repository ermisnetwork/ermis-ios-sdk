//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class StickerHeaderCell: _CollectionViewCell, UIProvider {
    public private(set) lazy var itemView = components.stickerHeaderItemView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "itemView")

    open override func setUpUI() {
        super.setUpUI()
        embed(itemView)
    }

    open override func setUpTheme() {
        super.setUpTheme()
    }
}
