//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// `UICollectionViewCell` for the reaction's author view.
open class MessageReactionAuthorViewCell: _CollectionViewCell, UIProvider {
    open class var reuseId: String { String(describing: self) }

    /// The content of reaction author view cell.
    public struct Content {
        /// The reaction of the message.
        public var reaction: MessageReaction
        /// The id of the current logged in user.
        public var currentUserId: UserId

        public init(
            reaction: MessageReaction,
            currentUserId: UserId
        ) {
            self.reaction = reaction
            self.currentUserId = currentUserId
        }
    }

    /// The content of reaction author view cell.
    open var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The container stack that composes the author avatar view and the author name label.
    open lazy var containerStack = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "containerStack")

    /// The author's avatar view.
    open lazy var authorAvatarView: AvatarView = components
        .avatarView.init(style: .circular)
        .withoutAutoresizingMaskConstraints

    /// The author's name label.
    open lazy var authorNameLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory

    /// The bubble view around the message reaction.
    open lazy var reactionBubbleView: ReactionBubbleBaseView = components
        .messageReactionsBubbleView.init()
        .withoutAutoresizingMaskConstraints

    /// The reaction view inside the reaction bubble.
    public lazy var reactionItemView: MessageReactionItemView = components
        .messageReactionItemView.init()
        .withoutAutoresizingMaskConstraints

    /// The constraint that if active renders the reaction in the leading side of the avatar view.
    public var reactionLeadingConstraint: NSLayoutConstraint?

    /// The constraint that if active renders the reaction in the trailing side of the avatar view.
    public var reactionTrailingConstraint: NSLayoutConstraint?

    /// The size of the avatar view that belongs to the author of the reaction.
    open var authorAvatarSize: CGSize { .init(width: 64, height: 64) }

    override open func setUpTheme() {
        super.setUpTheme()

        authorNameLabel.font = theme.fonts.footnote.bold
        authorNameLabel.textAlignment = .center
        authorNameLabel.numberOfLines = 2
        authorNameLabel.adjustsFontSizeToFitWidth = true
    }

    override open func setUpUI() {
        super.setUpUI()

        containerStack.axis = .vertical
        containerStack.alignment = .top
        containerStack.spacing = 8
        containerStack.distribution = .natural

        contentView.addSubview(containerStack)
        NSLayoutConstraint.activate([
            containerStack.leadingAnchor.pin(equalTo: contentView.leadingAnchor),
            containerStack.trailingAnchor.pin(equalTo: contentView.trailingAnchor),
            containerStack.topAnchor.pin(equalTo: contentView.topAnchor)
        ])

        containerStack.addArrangedSubview(authorAvatarView)
        containerStack.addArrangedSubview(authorNameLabel)
        authorAvatarView.addSubview(reactionBubbleView)

        reactionBubbleView.addSubview(reactionItemView)
        reactionItemView.pin(to: reactionBubbleView.layoutMarginsGuide)

        NSLayoutConstraint.activate([
            authorAvatarView.widthAnchor.pin(equalToConstant: authorAvatarSize.width),
            authorAvatarView.heightAnchor.pin(equalToConstant: authorAvatarSize.height),
            authorNameLabel.widthAnchor.pin(equalTo: authorAvatarView.widthAnchor),
            reactionBubbleView.bottomAnchor.pin(equalTo: authorAvatarView.bottomAnchor)
        ])

        reactionTrailingConstraint = reactionBubbleView.rightAnchor.pin(equalTo: authorAvatarView.centerXAnchor)
        reactionLeadingConstraint = reactionBubbleView.leftAnchor.pin(equalTo: authorAvatarView.centerXAnchor)

        reactionTrailingConstraint?.isActive = false
        reactionLeadingConstraint?.isActive = false
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        guard let content = self.content else {
            reactionItemView.content = nil
            authorNameLabel.text = nil
            authorAvatarView.imageView.image = nil
            return
        }

        authorAvatarView.loadImage(from: content.reaction.author.imageURL,
                                   with: ImageLoaderOptions(
                                    resize: .init(authorAvatarSize),
                                    placeHolderString: content.reaction.author.displayName
                                   ))

        let reactionAuthor = content.reaction.author
        let isCurrentUser = content.currentUserId == reactionAuthor.id

        authorNameLabel.text = isCurrentUser ? L10n.you : reactionAuthor.name

        reactionBubbleView.tailDirection = isCurrentUser ? .toTrailing : .toLeading
        reactionItemView.content = .init(
            useBigIcon: false,
            reaction: MessageReactionData(
                type: content.reaction.type,
                score: content.reaction.score,
                isChosenByCurrentUser: isCurrentUser
            ),
            showReactionCount: false,
            onTap: nil
        )

        reactionTrailingConstraint?.isActive = isCurrentUser
        reactionLeadingConstraint?.isActive = !isCurrentUser
    }

    open override func prepareForReuse() {
        super.prepareForReuse()
        authorAvatarView.cancelLoading()
    }
}
