//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

open class ForwardingMessageCell: _TableViewCell, UIProvider {
    public private(set) lazy var itemView = components
        .forwardingItemView.init()
        .withoutAutoresizingMaskConstraints

    public var content: Content? {
        didSet {
            contentDidChanged()
        }
    }

    public weak var itemviewDelegate: ForwardingMessageItemViewDelegate?

    // MARK: - Setup
    open override func setUp() {
        selectionStyle = .none
    }

    open override func setUpUI() {
        contentView.embed(itemView)
    }

    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        contentView.backgroundColor = theme.colors.surface
    }

    open override func contentDidChanged() {
        itemView.content = content
        itemView.delegate = itemviewDelegate
    }

    open func createForwardingButton() -> UIButton {
        let button = UIButton()
        return button
    }
}

public extension ForwardingMessageCell {
    struct Content {
        let channel: Channel
        let forwardingState: ForwardingMessageViewController.ForwardingState
    }
}
