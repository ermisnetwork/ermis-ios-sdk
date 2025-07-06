//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The decorator view that is used to display the unread messages count in a channel.
open class UnreadMessagesCountDecorationView: MessageCellHeaderFooterView, UIProvider {
    public var content: Channel? {
        didSet {
            updateContentIfNeeded()
        }
    }

    lazy var messagesCountDecorationView = components.messagesCountDecorationView.init()
        .withoutAutoresizingMaskConstraints

    override open func setUpUI() {
        super.setUpUI()

        embed(messagesCountDecorationView, insets: .init(top: 8, leading: 0, bottom: 0, trailing: 0))
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        // Temporarily disabling unread counts as they are not 100% accurate all the time.
        // Passing 0 will show "Unread messages" without a number
        // let unreadCount = content?.unreadCount.messages ?? 0
        let unreadCount = 0
        messagesCountDecorationView.textLabel.text = L10n.Message.Unread.count(unreadCount)
    }
}
