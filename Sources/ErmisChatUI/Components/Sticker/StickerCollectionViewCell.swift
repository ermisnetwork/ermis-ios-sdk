//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit

open class StickerCollectionViewCell: _CollectionViewCell, UIProvider {
    open private(set) lazy var itemView = components.stickerItemView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "stickerItemView")

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        embed(itemView)
    }

    open override func prepareForReuse() {
        super.prepareForReuse()
        itemView.stickerPreview.prepareForReuse()
    }
}

