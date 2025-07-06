//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that shows a number of unread messages in channel.
open class UnreadCountView: _View, UIProvider, SwiftUIRepresentable {
    /// The `UILabel` instance that holds number of unread messages.
    open private(set) lazy var unreadCountLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "unreadCountLabel")

    /// The data this view component shows.
    open var content: Content = .init(channelUnreadCount: .noUnread) {
        didSet { updateContentIfNeeded() }
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override open func setUpTheme() {
        super.setUpTheme()
        layer.masksToBounds = true
        backgroundColor = theme.colors.channelUnreadcountBackground

        unreadCountLabel.textColor = theme.colors.channelUnreadcountText
        unreadCountLabel.font = theme.fonts.footnote.bold
        unreadCountLabel.textAlignment = .center
    }

    override open func setUpUI() {
        // 2 and 3 are magic numbers that look visually good
        layoutMargins = .init(top: 2, left: 3, bottom: 2, right: 3)

        addSubview(unreadCountLabel)
        unreadCountLabel.pin(to: layoutMarginsGuide)

        // The width shouldn't be smaller than height because we want to show it as a circle for small numbers
        widthAnchor.pin(greaterThanOrEqualTo: heightAnchor, multiplier: 1).isActive = true
    }

    override open func contentDidChanged() {
        isHidden = content.unreadCount == 0
        unreadCountLabel.text = String(content.unreadCount)
    }
}

public
extension UnreadCountView {
    struct Content {
        public var unreadCount: Int = 0

        public init(unreadCount: Int) {
            self.unreadCount = unreadCount
        }

        public init(channelUnreadCount: ChannelUnreadCount) {
            self.unreadCount = channelUnreadCount.messages
        }
    }
}
