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

    open var totalReactionsCount: Int {
        return content?.reactions.reduce(into: 0) { partialResult, reactionData in
            partialResult += reactionData.score
        } ?? 0
    }

    /// The sorting order of how the reactions data will be displayed.
    open var reactionsSorting: ((MessageReactionData, MessageReactionData) -> Bool) {
        components.reactionsSorting
    }

    // MARK: - Subviews

    public private(set) lazy var stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillProportionally
        stack.spacing = 0
        stack.isLayoutMarginsRelativeArrangement = false
        stack.directionalLayoutMargins = .zero
        stack.layoutMargins = .zero
        return stack.withoutAutoresizingMaskConstraints
    }()

    public private(set) lazy var totalReactionCountLabel = UILabel()
        .withAccessibilityIdentifier(identifier: "totalReactionCountLabel")
        .withoutAutoresizingMaskConstraints

    // MARK: - Overrides

    override open func setUpUI() {
        embed(stackView)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        totalReactionCountLabel.textColor = theme.colors.text
        totalReactionCountLabel.font = theme.fonts.footnote
    }

    override open func contentDidChanged() {
        stackView.arrangedSubviews.forEach {
            $0.removeFromSuperview()
        }

        guard let content = content else { return }

        stackView.spacing = content.useBigIcons ? 10 : 0
        
        content.reactions.forEach { reaction in
            if theme.icons.availableReactions[reaction.type] == nil {
                logWarning(unavailableReaction: reaction)
                return
            }
            let itemView = reactionItemView.init()
            let showReactionCount = !content.useBigIcons && !content.showTotalCount
            if !showReactionCount {
                itemView.widthAnchor.pin(equalTo: itemView.heightAnchor).isActive = true
            }
            itemView.content = .init(
                useBigIcon: content.useBigIcons,
                reaction: reaction,
                showReactionCount: showReactionCount,
                onTap: content.didTapOnReaction
            )
            stackView.addArrangedSubview(itemView)
        }

        if content.showTotalCount {
            stackView.addArrangedSubview(totalReactionCountLabel)
            totalReactionCountLabel.text = "\(totalReactionsCount)"
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
        public let showTotalCount: Bool
        public let didTapOnReaction: ((MessageReactionType) -> Void)?

        public init(
            useBigIcons: Bool,
            reactions: [MessageReactionData],
            showTotalCount: Bool,
            didTapOnReaction: ((MessageReactionType) -> Void)?
        ) {
            self.useBigIcons = useBigIcons
            self.reactions = reactions
            self.showTotalCount = showTotalCount
            self.didTapOnReaction = didTapOnReaction
        }
    }
}
