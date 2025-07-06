//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The date separator view that groups messages from the same day.
open class MessageListDateSeparatorView: MessageCellHeaderFooterView, ThemeProvider {
    /// The date in string format.
    open var content: String? {
        didSet { updateContentIfNeeded() }
    }

    /// The container that the contentTextLabel will be placed aligned to its centre.
    open private(set) lazy var container: UIView = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "dateSeparatorContainer")

    /// The text label that renders the date string.
    open private(set) lazy var textLabel: UILabel = UILabel()
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "textLabel")

    override open func setUpUI() {
        super.setUpUI()

        addSubview(container)

        container.embed(textLabel, insets: .init(top: 3, leading: 9, bottom: 3, trailing: 9))

        NSLayoutConstraint.activate([
            container.leadingAnchor.pin(greaterThanOrEqualTo: leadingAnchor),
            container.trailingAnchor.pin(lessThanOrEqualTo: trailingAnchor),
            container.topAnchor.pin(equalTo: topAnchor),
            container.bottomAnchor.pin(equalTo: bottomAnchor),
            container.centerXAnchor.pin(equalTo: centerXAnchor)
        ])
    }

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = nil
        container.backgroundColor = theme.colors.messageListSeparatorBackground

        textLabel.font = theme.fonts.footnote
        textLabel.textColor = theme.colors.messageListSeparatorText
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        textLabel.text = content
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        container.layer.cornerRadius = bounds.height / 2
    }
}
