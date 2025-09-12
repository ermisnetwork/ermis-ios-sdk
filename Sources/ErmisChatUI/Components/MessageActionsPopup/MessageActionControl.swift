//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button for action displayed in `MessageActionsView`.
open class MessageActionControl: _Control, ThemeProvider {
    /// The data this view component shows.
    public var content: MessageActionItem? {
        didSet { updateContentIfNeeded() }
    }

    override open var isHighlighted: Bool {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// `ContainerStackView` that encapsulates `titleLabel` and `imageView`.
    public lazy var containerStackView: ContainerStackView = ContainerStackView(alignment: .center)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "containerStackView")

    /// `UILabel` to show `title`.
    public lazy var titleLabel: UILabel = UILabel()
        .withAccessibilityIdentifier(identifier: "titleLabel")
        .withNumberOfLines(2)

    /// `UIImageView` to show `image`.
    public lazy var imageView: UIImageView = UIImageView()
        .withAccessibilityIdentifier(identifier: "imageView")

    override open func setUpTheme() {
        super.setUpTheme()

        titleLabel.font = theme.fonts.body
        titleLabel.adjustsFontForContentSizeCategory = true
    }

    override open func setUp() {
        super.setUp()

        containerStackView.isUserInteractionEnabled = false
        containerStackView.insetsLayoutMarginsFromSafeArea = false
        addTarget(self, action: #selector(touchUpInsideHandler(_:)), for: .touchUpInside)
    }

    override open func setUpUI() {
        super.setUpUI()
        embed(containerStackView)
        containerStackView.isLayoutMarginsRelativeArrangement = true

        containerStackView.addArrangedSubview(imageView)
        containerStackView.addArrangedSubview(titleLabel.flexible(axis: .horizontal))
    }

    override open func tintColorDidChange() {
        super.tintColorDidChange()

        guard UIApplication.shared.applicationState == .active else { return }
        updateContentIfNeeded()
    }

    override open func contentDidChanged() {
        let imageTintСolor: UIColor
        let titleTextColor: UIColor

        if content?.isDestructive == true {
            imageTintСolor = theme.colors.error
            titleTextColor = imageTintСolor
        } else {
            imageTintСolor = content?.isPrimary == true ? tintColor : theme.colors.text
            titleTextColor = theme.colors.text
        }

        titleLabel.text = content?.title
        if isHighlighted {
            titleLabel.textColor = theme.colors.highlightedColorForColor(titleTextColor)
            imageView.image = content?.icon
                .tinted(with: theme.colors.highlightedColorForColor(imageTintСolor))
            backgroundColor = theme.colors.highlightedColorForColor(theme.colors.surface)
        } else {
            titleLabel.textColor = titleTextColor
            imageView.image = content?.icon
                .tinted(with: imageTintСolor)
            backgroundColor = theme.colors.surface
        }
    }

    /// Triggered when `MessageActionControl` is tapped.
    @objc open func touchUpInsideHandler(_ sender: Any) {
        guard let content = content else { return log.assertionFailure("Content is unexpectedly nil") }
        content.action(content)
    }
}
