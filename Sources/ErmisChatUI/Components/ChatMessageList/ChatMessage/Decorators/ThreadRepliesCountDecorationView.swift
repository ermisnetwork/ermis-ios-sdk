//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The decorator view that is used to display the replies count in a thread
open class ThreadRepliesCountDecorationView: MessageCellHeaderFooterView, UIProvider {
    public var content: ChatMessage? {
        didSet {
            updateContentIfNeeded()
        }
    }

    lazy var messagesCountDecorationView = components.messagesCountDecorationView.init()
        .withoutAutoresizingMaskConstraints

    override open func setUpUI() {
        super.setUpUI()

        embed(messagesCountDecorationView, insets: .init(top: 0, leading: 0, bottom: 8, trailing: 0))
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        messagesCountDecorationView.textLabel.text = L10n.Message.Thread.Replies.count(content?.replyCount ?? 0)
    }
}
