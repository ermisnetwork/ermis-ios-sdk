//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// View which holds one or more file attachment views in a message or composer attachment view
open class MessageStickerView: _View, ComponentsProvider, ThemeProvider {

    public private(set) lazy var stickerPreview: StickerPreview = components.stickerPreview.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "stickerPreview")

    public var content: URL? {
        didSet {
            updateContentIfNeeded()
        }
    }

    open override func setUp() {
        
    }

    open override func setUpUI() {
        embed(stickerPreview)
    }

    open override func setUpTheme() {
        stickerPreview.backgroundColor = theme.colors.surface
    }

    open override func contentDidChanged() {
        guard let url = content else {
            stickerPreview.content = nil
            return
        }
        stickerPreview.content = .init(url: url, sticker: nil)
    }
}
