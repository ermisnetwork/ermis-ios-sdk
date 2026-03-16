//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public class StickerViewInjector: CustomCellViewInjector {

    public override var customView: UIView? {
        return stickerView
    }

    public override var fillAllAvailableWidth: Bool {
        return false
    }

    open lazy var stickerView: MessageStickerView = {
        let stickerView = contentView
            .components
            .stickerView
            .init()

        return stickerView.withoutAutoresizingMaskConstraints
    }()

    override open func contentViewDidLayout(options: MessageLayoutOptions) {
        super.contentViewDidLayout(options: options)
        stickerView.pin(anchors: [.width, .height], to: 150)
    }

    override open func contentViewContentDidChanged() {
        stickerView.content = contentView.content?.stickerUrl
    }

    public override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
        stickerView.content = nil
    }
}
