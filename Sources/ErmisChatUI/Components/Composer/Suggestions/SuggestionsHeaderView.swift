//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The header view of the suggestion collection view.
open class SuggestionsHeaderView: _View, ThemeProvider {
    /// The image icon of the commands header view.
    open private(set) lazy var commandImageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    /// The text label of the commands header view.
    open private(set) lazy var headerLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = theme.colors.surfaceContainer

        headerLabel.font = theme.fonts.body
        headerLabel.textColor = theme.colors.subtitleText
        commandImageView.contentMode = .scaleAspectFit
    }

    override open func setUpUI() {
        let view = UIView().withoutAutoresizingMaskConstraints
        embed(view, insets: directionalLayoutMargins)

        view.addSubview(commandImageView)
        view.addSubview(headerLabel)
        commandImageView.pin(anchors: [.leading], to: view)
        commandImageView.pin(anchors: [.centerY], to: view)

        NSLayoutConstraint.activate(
            [
                commandImageView.centerYAnchor.pin(equalTo: headerLabel.centerYAnchor),
                headerLabel.centerYAnchor.pin(equalTo: commandImageView.centerYAnchor),
                headerLabel.leadingAnchor.pin(
                    equalToSystemSpacingAfter: commandImageView.trailingAnchor,
                    multiplier: 2
                )
            ]
        )
    }
}
