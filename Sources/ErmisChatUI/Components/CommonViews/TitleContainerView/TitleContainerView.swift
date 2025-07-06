//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays a title label and subtitle in a container stack view.
open class TitleContainerView: _View, ThemeProvider, SwiftUIRepresentable {
    /// Content of the view that contains title (first line) and subtitle (second nil)
    open var content: Content = .init(title: nil, subtitle: nil) {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// Label that represents the first line of the view
    open private(set) lazy var titleLabel: UILabel = UILabel()
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory

    /// Label that represents the second line of the view
    open private(set) lazy var subtitleLabel: UILabel = UILabel()
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory

    /// A view that acts as the main container for the subviews
    open private(set) lazy var containerView: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "containerView")

    override open func setUpTheme() {
        super.setUpTheme()

        titleLabel.font = theme.fonts.headline.bold
        titleLabel.textColor = theme.colors.text

        subtitleLabel.font = theme.fonts.caption1
        subtitleLabel.textColor = theme.colors.subtitleText
    }

    override open func setUp() {
        super.setUp()

        titleLabel.textAlignment = .center
        subtitleLabel.textAlignment = .center

        containerView.axis = .vertical
        containerView.alignment = .center
        containerView.spacing = 0
    }

    override open func setUpUI() {
        super.setUpUI()

        containerView.addArrangedSubviews([titleLabel, subtitleLabel])
        embed(containerView)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        titleLabel.isHidden = content.title == nil
        titleLabel.text = content.title

        subtitleLabel.isHidden = content.subtitle == nil
        subtitleLabel.text = content.subtitle
    }
}

public extension TitleContainerView {
    struct Content {
        public var title: String?
        public var subtitle: String?

        public init(title: String? = nil, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }
}
