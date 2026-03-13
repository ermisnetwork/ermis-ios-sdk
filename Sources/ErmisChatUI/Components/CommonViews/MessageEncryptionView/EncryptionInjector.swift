//
// Copyright 2025 Ermis Inc.
//

import UIKit

open class EncryptionInjector: CustomCellViewInjector {
    public override var customView: UIView? {
        messageEncryptionView
    }

    open override var fillAllAvailableWidth: Bool {
        return false
    }

    open private(set) lazy var messageEncryptionView = contentView
        .components
        .messageEncryptionView.init()
        .withoutAutoresizingMaskConstraints

    open override func contentViewDidLayout(options: MessageLayoutOptions) {
//        super.contentViewDidLayout(options: options)
        contentView.bubbleContentContainer.insertArrangedSubview(messageEncryptionView, at: 0)
        messageEncryptionView.pin(anchors: [.width, .height], to: 25)
    }

    open override func contentViewContentDidChanged() {
        super.contentViewContentDidChanged()
        messageEncryptionView.contentDidChanged()
    }

    open override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
    }
}
