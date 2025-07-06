//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A Button that is used to indicate unread messages in the Message list.
open class JumpToUnreadMessagesButton: _Button, UIProvider {
    /// The unread count that will be shown on the button as a badge icon.
    var content: ChannelUnreadCount = .noUnread {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The view showing number of unread messages in channel if any.
    open private(set) lazy var textLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory

    open private(set) lazy var closeButton = UIButton().withoutAutoresizingMaskConstraints

    override open func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2
    }

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = theme.colors.jumpToUnreadMessageButtonBackground
        layer.addShadow(color: theme.colors.jumpToUnreadMessageButtonBorder)
        textLabel.font = theme.fonts.footnote
        textLabel.textColor = theme.colors.text
        closeButton.setImage(theme.icons.discard, for: .normal)
        closeButton.tintColor = theme.colors.text
    }

    override open func setUpUI() {
        super.setUpUI()

        addSubview(textLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.pin(equalTo: leadingAnchor, constant: 12),
            textLabel.topAnchor.pin(equalTo: topAnchor, constant: 10),
            textLabel.bottomAnchor.pin(equalTo: bottomAnchor, constant: -10),
            closeButton.leadingAnchor.pin(equalTo: textLabel.trailingAnchor, constant: 2),
            closeButton.topAnchor.pin(greaterThanOrEqualTo: topAnchor),
            closeButton.centerYAnchor.pin(equalTo: centerYAnchor),
            closeButton.bottomAnchor.pin(lessThanOrEqualTo: bottomAnchor),
            closeButton.trailingAnchor.pin(equalTo: trailingAnchor, constant: -10)
        ])
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        textLabel.text = L10n.MessageList.jumpToUnreadButton(content.messages)
    }

    open func addTarget(_ target: Any?, action: Selector) {
        addTarget(target, action: action, for: .touchUpInside)
    }

    open func addDiscardButtonTarget(_ target: Any?, action: Selector) {
        closeButton.addTarget(target, action: action, for: .touchUpInside)
    }
}
