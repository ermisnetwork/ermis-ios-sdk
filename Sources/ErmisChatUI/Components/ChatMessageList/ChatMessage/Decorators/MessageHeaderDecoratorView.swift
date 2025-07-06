//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public struct ChannelMessageHeaderDecoratorViewContent {
    public let message: ChatMessage
    public let channel: Channel
    public let dateFormatter: MessageDateSeparatorFormatter
    public let shouldShowDate: Bool
    public let shouldShowUnreadMessages: Bool

    public init(
        message: ChatMessage,
        channel: Channel,
        dateFormatter: MessageDateSeparatorFormatter,
        shouldShowDate: Bool,
        shouldShowUnreadMessages: Bool
    ) {
        self.message = message
        self.channel = channel
        self.dateFormatter = dateFormatter
        self.shouldShowDate = shouldShowDate
        self.shouldShowUnreadMessages = shouldShowUnreadMessages
    }
}

/// The decorator view that is used as a container for the chat message header view decorators.
public final class ChannelMessageHeaderDecoratorView: MessageCellHeaderFooterView, UIProvider {
    /// The container for the stacked views.
    public private(set) lazy var container = UIStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "messageHeaderDecoratorView")

    public private(set) lazy var dateView = components.messageListDateSeparatorView.init()
        .withoutAutoresizingMaskConstraints
    public private(set) lazy var unreadCountView = components.unreadMessagesCounterDecorationView.init()
        .withoutAutoresizingMaskConstraints

    public var content: ChannelMessageHeaderDecoratorViewContent? {
        didSet {
            updateContentIfNeeded()
        }
    }

    override public func setUpUI() {
        super.setUpUI()
        embed(container, insets: .init(top: 0, leading: 0, bottom: 0, trailing: 0))
        container.axis = .vertical
        container.spacing = 4

        [dateView, unreadCountView].forEach(container.addArrangedSubview)
    }

    override public func setUpTheme() {
        super.setUpTheme()
        backgroundColor = nil
    }

    override public func contentDidChanged() {
        super.contentDidChanged()
        dateView.isVisible = content?.shouldShowDate ?? false
        unreadCountView.isVisible = content?.shouldShowUnreadMessages ?? false
        dateView.content = content.map { $0.dateFormatter.format($0.message.createdAt) }
        unreadCountView.content = content?.channel
    }
}
