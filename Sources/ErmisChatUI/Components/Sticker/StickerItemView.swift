//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class StickerItemView: _View, UIProvider {
    open private(set) lazy var stickerPreview = components.stickerPreview.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "stickerPreview")

    public var content: Sticker? {
        didSet {
            updateContentIfNeeded()
        }
    }

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        embed(stickerPreview)
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        guard let urlString = content?.url, let url = URL(string: urlString) else {
            stickerPreview.content = nil
            return
        }
        stickerPreview.content = .init(url: url, sticker: content)
    }
}

