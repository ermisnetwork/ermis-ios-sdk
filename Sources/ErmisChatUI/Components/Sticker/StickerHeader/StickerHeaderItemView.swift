//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class StickerHeaderItemView: _View, UIProvider {
    open private(set) lazy var stickerPreview = components.stickerPreview.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "stickerPreview")

    public var content: StickerListViewController.Item? {
        didSet {
            updateContentIfNeeded()
        }
    }

    public var isSelected: Bool = false {
        didSet {
            self.backgroundColor = isSelected ? theme.colors.surfaceContainer : .clear
        }
    }

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        addSubview(stickerPreview)
        stickerPreview.pin(anchors: [.centerX, .centerY], to: self)
        stickerPreview.pin(anchors: [.width, .height], to: 30)
        self.layer.cornerRadius = 8
    }

    open override func setUpTheme() {
        super.setUpTheme()
        self.backgroundColor = isSelected ? theme.colors.surfaceContainer : .clear
        if content?.sectionId == StickerPack.recentsPackId {
            stickerPreview.imageView.tintColor = theme.colors.primary
        } else {
            stickerPreview.imageView.tintColor = nil
        }
    }

    open override func contentDidChanged() {
        guard let content else {
            stickerPreview.prepareForReuse()
            return
        }
        if content.sectionId ==  StickerPack.recentsPackId {
            stickerPreview.prepareForReuse()
            stickerPreview.imageView.image = theme.icons.recents
            stickerPreview.imageView.tintColor = theme.colors.primary
        } else {
            if let urlString = content.sticker.url, let url = URL(string: urlString) {
                stickerPreview.content = .init(url: url, sticker: content.sticker)
            } else {
                stickerPreview.prepareForReuse()
            }
        }
    }
}
