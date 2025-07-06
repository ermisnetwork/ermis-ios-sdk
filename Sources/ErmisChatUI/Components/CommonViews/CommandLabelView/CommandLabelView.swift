//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that display the command name and icon.
open class CommandLabelView: _View, ThemeProvider, SwiftUIRepresentable {
    /// The command that the label displays.
    public var content: Command? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The container stack view that layouts the label and the icon view.
    public private(set) lazy var container = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "container")

    /// An `UILabel` that displays the command name.
    public private(set) lazy var nameLabel = UILabel()
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "nameLabel")

    /// An `UIImageView` that displays the icon of the command.
    public private(set) lazy var iconView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "iconView")

    override open var intrinsicContentSize: CGSize {
        container.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2
    }

    override open func setUpTheme() {
        super.setUpTheme()

        layer.masksToBounds = true
        backgroundColor = theme.colors.surfaceContainer

        nameLabel.textColor = theme.colors.subTitleTextHigh
        nameLabel.font = theme.fonts.subheadline.bold

        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center

        iconView.image = theme.icons.commands
            .tinted(with: theme.colors.text)
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(container)
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins.top = 4
        container.layoutMargins.bottom = 4

        container.addArrangedSubview(iconView)
        container.addArrangedSubview(nameLabel)
        iconView.isHidden = false
        nameLabel.isHidden = false

        iconView.contentMode = .scaleAspectFit
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        nameLabel.text = content?.name.uppercased()
    }
}
