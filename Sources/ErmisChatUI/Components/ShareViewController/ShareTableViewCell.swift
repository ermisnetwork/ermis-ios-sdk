//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

open class ShareTableViewCell: _TableViewCell, UIProvider {
    public private(set) lazy var itemView = components
        .shareItemView.init()
        .withoutAutoresizingMaskConstraints

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

    open func createForwardingButton() -> UIButton {
        let button = UIButton()
        return button
    }

    open override func prepareForReuse() {
        super.prepareForReuse()
        itemView.content = nil
        itemView.delegate = nil
    }
}
