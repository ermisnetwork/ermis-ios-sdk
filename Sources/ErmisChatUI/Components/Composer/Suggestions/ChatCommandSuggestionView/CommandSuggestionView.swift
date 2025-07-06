//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays the command name, image and arguments.
open class CommandSuggestionView: _View, ThemeProvider {
    /// The command that the view will display.
    open var content: Command? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// A view that displays the command image icon.
    open private(set) lazy var commandImageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    /// A view that displays the name of the command.
    open private(set) lazy var commandNameLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport

    /// A view that display the command name and the possible arguments.
    open private(set) lazy var commandNameSubtitleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport

    /// A view container that holds the name and subtitle labels.
    open private(set) lazy var textContainer = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "textContainer")

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = .clear

        commandNameLabel.font = theme.fonts.body.bold
        commandNameLabel.textColor = theme.colors.text

        commandNameSubtitleLabel.font = theme.fonts.body
        commandNameSubtitleLabel.textColor = theme.colors.subtitleText
    }

    override open func setUpUI() {
        addSubview(commandImageView)
        setupLeftImageViewConstraints()

        addSubview(textContainer)
        setupStack()
        commandNameSubtitleLabel.setContentCompressionResistancePriority(.ermisLow, for: .horizontal)
    }

    override open func contentDidChanged() {
        guard let command = content else { return }
        commandNameSubtitleLabel.text = "/\(command.name) \(command.args)"
        commandNameLabel.text = command.name.firstUppercased

        commandImageView.image = theme.icons.commandIcons[command.name.lowercased()]
            ?? theme.icons.commandFallback
    }

    private func setupLeftImageViewConstraints() {
        commandImageView.leadingAnchor.pin(equalTo: layoutMarginsGuide.leadingAnchor).isActive = true
        commandImageView.topAnchor.pin(equalTo: layoutMarginsGuide.topAnchor).isActive = true
        commandImageView.bottomAnchor.pin(equalTo: layoutMarginsGuide.bottomAnchor).isActive = true
        commandImageView.widthAnchor.pin(equalTo: commandImageView.heightAnchor).isActive = true
        commandImageView.centerYAnchor.pin(equalTo: layoutMarginsGuide.centerYAnchor).isActive = true
        commandImageView.heightAnchor.pin(equalToConstant: 24).isActive = true
    }

    private func setupStack() {
        textContainer.axis = .horizontal
        textContainer.alignment = .leading

        textContainer.addArrangedSubview(commandNameLabel)
        textContainer.addArrangedSubview(commandNameSubtitleLabel)
        textContainer.leadingAnchor.pin(
            equalToSystemSpacingAfter: commandImageView.trailingAnchor,
            multiplier: 1
        ).isActive = true
        textContainer.trailingAnchor.pin(lessThanOrEqualTo: layoutMarginsGuide.trailingAnchor).isActive = true
        textContainer.centerYAnchor.pin(equalTo: commandImageView.centerYAnchor).isActive = true
    }
}
