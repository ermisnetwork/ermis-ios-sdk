//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view that renders a single reaction view button.
open class MessageReactionItemView: _Button, ThemeProvider {
    public struct Content {
        public let useBigIcon: Bool
        public let reaction: MessageReactionData
        public var showReactionCount: Bool
        public var onTap: ((MessageReactionType) -> Void)?

        public init(
            useBigIcon: Bool,
            reaction: MessageReactionData,
            showReactionCount: Bool = false,
            onTap: ((MessageReactionType) -> Void)?
        ) {
            self.useBigIcon = useBigIcon
            self.reaction = reaction
            self.showReactionCount = showReactionCount
            self.onTap = onTap
        }
    }

    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    override open var intrinsicContentSize: CGSize {
        super.intrinsicContentSize
    }

    open var reactionImageTint: UIColor? {
        guard let content = content else { return nil }

        return content.reaction.isChosenByCurrentUser ?
        theme.colors.currentUserReactionItemBackground : theme.colors.reactionItemBackground
    }

    open var reactionTextColor: UIColor? {
        guard let content = content else { return nil }
        
        return content.reaction.isChosenByCurrentUser ?
        theme.colors.currentUserReactionCountText : theme.colors.reactionCountText
    }

    // MARK: - Overrides

    override open func setUp() {
        super.setUp()

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        titleLabel?.font = theme.fonts.caption1

        if #available(iOS 15.0, *) {
            var configuration = self.configuration ?? UIButton.Configuration.bordered()
            configuration.background = .clear()
            configuration.contentInsets = .zero
            configuration.cornerStyle = .capsule
            self.configuration = configuration
        } else {
            self.contentEdgeInsets = .zero
            layer.borderWidth = 1
            backgroundColor = .clear
        }

    }

    override open func setUpUI() {
        super.setUpUI()

        setContentCompressionResistancePriority(.ermisRequire, for: .vertical)
        setContentCompressionResistancePriority(.ermisRequire, for: .horizontal)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()
        isUserInteractionEnabled = content?.onTap != nil
        guard var emojiAttributedString = emojiAttributedString() else {
            return
        }

        var attributedString = NSMutableAttributedString(
            attributedString: emojiAttributedString
        )

        if let content = content,
           content.reaction.score > 0,
           content.showReactionCount {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: theme.fonts.caption2,
                .foregroundColor: theme.colors.reactionCountText
            ]
            let countAttributedString = NSAttributedString(string: " \(content.reaction.score)",
                                                           attributes: attributes)
            attributedString.append(countAttributedString)
        }
        setAttributedTitle(attributedString, for: .normal)
        layer.borderColor = reactionImageTint?.cgColor

        if #available(iOS 15.0, *) {
            var configuration = self.configuration
            var bgConfiguration = UIBackgroundConfiguration.listPlainCell()
            bgConfiguration.backgroundColor = reactionImageTint
            configuration?.background = bgConfiguration
            self.configuration = configuration
            setNeedsUpdateConfiguration()
        } else {
            self.backgroundColor = reactionImageTint
        }
    }

    override open func tintColorDidChange() {
        super.tintColorDidChange()

        guard UIApplication.shared.applicationState == .active else { return }
        updateContentIfNeeded()
    }

    // MARK: - Actions

    @objc open func handleTap() {
        guard let content = self.content else { return }

        content.onTap?(content.reaction.type)
    }
    // MARK: - Helper
    private func emojiAttributedString() -> NSAttributedString? {
        guard let content = content,
              let reaction = theme.icons.availableReactions[content.reaction.type] else { return nil }

        return NSAttributedString(string: reaction.emojiString,
                                  attributes: [
                                    .font: content.useBigIcon ? theme.fonts.body : theme.fonts.caption2
        ])
    }
}
