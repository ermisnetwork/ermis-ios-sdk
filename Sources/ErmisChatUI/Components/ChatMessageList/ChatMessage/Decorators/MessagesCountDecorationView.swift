//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view used to show a separator when there are unread messages.
open class MessagesCountDecorationView: MessageCellHeaderFooterView, ThemeProvider {
    /// The container that the contentTextLabel will be placed aligned to its centre.
    open private(set) lazy var container: UIView = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "messagesCountDecorationView")

    /// The text label that renders the date string.
    open private(set) lazy var textLabel: UILabel = UILabel()
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "textLabel")

    override open func setUpUI() {
        super.setUpUI()

        embed(container)
        container.embed(textLabel, insets: .init(top: 3, leading: 9, bottom: 3, trailing: 9))
    }

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = nil
        container.backgroundColor = theme.colors.surfaceContainerHigh

        textLabel.font = theme.fonts.caption1.bold
        textLabel.textColor = theme.colors.subTitleTextLow
        textLabel.textAlignment = .center
    }
}
