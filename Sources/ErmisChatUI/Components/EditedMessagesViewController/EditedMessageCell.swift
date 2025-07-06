//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class EditedMessageCell: _TableViewCell, UIProvider {
    /// Shows message author avatar.
    public private(set) lazy var itemView = components
        .editedMessageListItemView
        .init()
        .withoutAutoresizingMaskConstraints

    public var content: MessageEditHistory? {
        didSet {
            itemView.content = content
        }
    }

    // MARK: - Setup
    open override func setUp() {
    }

    open override func setUpUI() {
        contentView.embed(itemView)
    }

    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        contentView.backgroundColor = theme.colors.surface
    }
}
