//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view that shows the list of reactions attached to the message.
open class MessageReactionsView: _View, UIProvider {
    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    open var reactionItemView: MessageReactionItemView.Type {
        components.messageReactionItemView
    }

    /// The sorting order of how the reactions data will be displayed.
    open var reactionsSorting: ((MessageReactionData, MessageReactionData) -> Bool) {
        components.reactionsSorting
    }

    // MARK: - Subviews

    public private(set) lazy var stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = UIStackView.spacingUseSystem
        return stack.withoutAutoresizingMaskConstraints
    }()

    // MARK: - Overrides

    override open func setUpUI() {
        embed(stackView)
    }

    override open func contentDidChanged() {
        stackView.arrangedSubviews.forEach {
            $0.removeFromSuperview()
        }

        guard let content = content else { return }

        content.reactions.forEach { reaction in
            if theme.icons.availableReactions[reaction.type] == nil {
                logWarning(unavailableReaction: reaction)
                return
            }
            let itemView = reactionItemView.init()
            itemView.content = .init(
                useBigIcon: content.useBigIcons,
                reaction: reaction,
                showReactionCount: !content.useBigIcons,
                onTap: content.didTapOnReaction
            )
            stackView.addArrangedSubview(itemView)
        }
    }

    private func logWarning(unavailableReaction reaction: MessageReactionData) {
        log.warning(
            "reaction with type \(reaction.type) is not registered in theme.icons.availableReactions, skipping"
        )
    }
}

// MARK: - Content

extension MessageReactionsView {
    public struct Content {
        public let useBigIcons: Bool
        public let reactions: [MessageReactionData]
        public let didTapOnReaction: ((MessageReactionType) -> Void)?

        public init(
            useBigIcons: Bool,
            reactions: [MessageReactionData],
            didTapOnReaction: ((MessageReactionType) -> Void)?
        ) {
            self.useBigIcons = useBigIcons
            self.reactions = reactions
            self.didTapOnReaction = didTapOnReaction
        }
    }
}
