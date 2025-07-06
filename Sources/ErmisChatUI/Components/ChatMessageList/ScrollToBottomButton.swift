//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A Button that is used to indicate unread messages in the Message list.
open class ScrollToBottomButton: _Button, UIProvider {
    /// The unread count that will be shown on the button as a badge icon.
    var content: ChannelUnreadCount = .noUnread {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The view showing number of unread messages in channel if any.
    open private(set) lazy var unreadCountView: MessageListUnreadCountView = components
        .messageListUnreadCountView
        .init()
        .withoutAutoresizingMaskConstraints

    override open func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2
    }

    override open func setUpTheme() {
        super.setUpTheme()

        setImage(theme.icons.scrollDownArrow, for: .normal)
        backgroundColor = theme.colors.surfaceContainerHighest
        layer.addShadow(color: theme.colors.outline)
    }

    override open func setUpUI() {
        super.setUpUI()

        addSubview(unreadCountView)
        unreadCountView.centerXAnchor.pin(equalTo: centerXAnchor).isActive = true
        unreadCountView.centerYAnchor.pin(equalTo: topAnchor).isActive = true
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        unreadCountView.content = .init(channelUnreadCount: content)
        unreadCountView.invalidateIntrinsicContentSize()
    }
}
