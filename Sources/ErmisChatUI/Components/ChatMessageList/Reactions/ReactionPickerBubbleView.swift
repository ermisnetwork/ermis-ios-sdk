//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view that shows reactions bubble.
open class ReactionPickerBubbleView: _View, UIProvider {
    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    // MARK: - Subviews

    public private(set) lazy var contentView = components
        .reactionPickerReactionsView
        .init()
        .withoutAutoresizingMaskConstraints

    open var tailLeadingAnchor: NSLayoutXAxisAnchor { contentView.centerXAnchor }
    open var tailTrailingAnchor: NSLayoutXAxisAnchor { contentView.centerXAnchor }

    // MARK: - Overrides

    override open func setUpUI() {
        super.setUpUI()

        embed(contentView)
    }

    // MARK: - Life Cycle

    override open func contentDidChanged() {
        // We check if we have available images for the given type of reaction, if not, we hide the reaction.
        guard !(content?.reactions.compactMap { theme.icons.availableReactions[$0.type] }.isEmpty ?? false)
        else {
            isHidden = true
            return
        }

        isHidden = false
        contentView.content = content.flatMap {
            .init(
                useBigIcons: $0.style.isBig,
                reactions: $0.reactions,
                didTapOnReaction: $0.didTapOnReaction
            )
        }
    }
}

// MARK: - Content

extension ReactionPickerBubbleView {
    public struct Content {
        public let style: MessageReactionsBubbleStyle
        public let reactions: [MessageReactionData]
        public let didTapOnReaction: (MessageReactionType) -> Void

        public init(
            style: MessageReactionsBubbleStyle,
            reactions: [MessageReactionData],
            didTapOnReaction: @escaping (MessageReactionType) -> Void
        ) {
            self.style = style
            self.reactions = reactions
            self.didTapOnReaction = didTapOnReaction
        }
    }
}
