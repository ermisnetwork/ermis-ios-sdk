//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol PinnedMessageCellDelegate: AnyObject {
    func pinnedMessageCell(_ cell: PinnedMessageCell, didSelectedUnPin message: ChatMessage)
}

open class PinnedMessageCell: _TableViewCell, UIProvider {
    /// Shows message author avatar.
    public private(set) lazy var itemView = components
        .pinnedMessageListItemView
        .init()
        .withoutAutoresizingMaskConstraints
    
    public var content: PinnedMessageListItemView.Content? {
        didSet {
            itemView.content = content
        }
    }

    public weak var delegate: PinnedMessageCellDelegate?

    // MARK: - Setup
    open override func setUp() {
        itemView.delegate = self
    }
    
    open override func setUpUI() {
        contentView.embed(itemView)
    }
    
    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        contentView.backgroundColor = theme.colors.surface
    }
    
    open override func contentDidChanged() {
        
    }
}

// MARK: - PinnedMessageListItemViewDelegate
extension PinnedMessageCell: PinnedMessageListItemViewDelegate {
    public func pinnedMessageListItemViewDidSelectUnpin(_ view: PinnedMessageListItemView) {
        guard let message = content?.message else {
            return
        }
        delegate?.pinnedMessageCell(self, didSelectedUnPin: message)
    }
}
