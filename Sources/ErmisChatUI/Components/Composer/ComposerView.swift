//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// /// The composer view that layouts all the components to create a new message.
///
/// High level overview of the composer layout:
/// ```
/// |---------------------------------------------------------|
/// |                       headerView                        |
/// |---------------------------------------------------------|--|
/// | leadingContainer | inputMessageView | trailingContainer |  | = centerContainer
/// |---------------------------------------------------------|--|
/// |                     bottomContainer                     |
/// |---------------------------------------------------------|
/// ```
open class ComposerView: _View, UIProvider {
    /// The main container of the composer that layouts all the other containers around the message input view.
    public private(set) lazy var container = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "container")

    /// The header view that displays components above the message input view.
    public private(set) lazy var headerView = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "headerView")

    /// A view that displays the link metadata when typing links in the composer.
    open private(set) lazy var linkPreviewView = components
        .composerLinkPreviewView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "linkPreviewView")

    /// The container that displays the components below the message input view.
    public private(set) lazy var bottomContainer = UIStackView()
        .withAccessibilityIdentifier(identifier: "bottomContainer")

    /// The container that layouts the message input view and the leading/trailing containers around it.
    public private(set) lazy var centerContainer = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "centerContainer")

    /// The container that displays the components in the leading side of the message input view.
    public private(set) lazy var leadingContainer = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "leadingContainer")

    /// The container that displays the components in the trailing side of the message input view.
    public private(set) lazy var trailingContainer = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "trailingContainer")

    /// A view to to input content of the new message.
    public private(set) lazy var inputMessageView: InputMessageView = components
        .inputMessageView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "inputMessageView")

    /// A button to send the message.
    public private(set) lazy var sendButton: UIButton = components
        .sendButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "sendButton")

    /// A button to record an VoiceRecording.
    public private(set) lazy var recordButton: RecordButton = components
        .recordButton
        .init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "recordButton")

    /// A view for showing a cooldown when Slow Mode is active.
    public private(set) lazy var cooldownView: CooldownView = components
        .cooldownView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "cooldownView")

    /// A button to confirm when editing a message.
    public private(set) lazy var confirmButton: UIButton = components
        .confirmButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "confirmButton")

    /// A button to select emoj / sticker.
    public private(set) lazy var stickerButton: UIButton = components
        .stickerButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "stickerButton")

    /// A button to open the user attachments.
    public private(set) lazy var photoButton: UIButton = components
        .photoButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "photoButton")

    /// A button to open the available commands.
    public private(set) lazy var commandsButton: UIButton = components
        .commandsButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "commandsButton")

    /// A Button for showing actions menu.
    public private(set) lazy var composerMenuButton: ComposerMenuButton = components
        .composerMenu.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "shrinkInputButton")

    /// A button to dismiss the current state (quoting, editing, etc..).
    public private(set) lazy var dismissButton: UIButton = components
        .closeButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "dismissButton")

    /// A label part of the header view to display the current state (quoting, editing, etc..).
    public private(set) lazy var titleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withAccessibilityIdentifier(identifier: "titleLabel")

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = theme.colors.surface
        layer.shadowColor = UIColor.systemGray.cgColor
        layer.shadowOpacity = 1
        layer.shadowOffset = .zero
        layer.shadowRadius = 0.5

        titleLabel.textAlignment = .center
        titleLabel.textColor = theme.colors.text
        titleLabel.font = theme.fonts.body.bold
        titleLabel.adjustsFontForContentSizeCategory = true
    }

    override open func setUpUI() {
        super.setUpUI()
        embed(container)

        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = .init(top: 8, left: 4, bottom: 8, right: 4)
        container.axis = .vertical
        container.alignment = .fill
        container.addArrangedSubview(headerView)
        container.addArrangedSubview(linkPreviewView)
        container.addArrangedSubview(centerContainer)
        container.addArrangedSubview(bottomContainer)
        bottomContainer.isHidden = true
        headerView.isHidden = true
        linkPreviewView.isHidden = true

        headerView.addSubview(titleLabel)
        headerView.addSubview(dismissButton)

        centerContainer.axis = .horizontal
        centerContainer.alignment = .bottom
        centerContainer.spacing = 2
        centerContainer.addArrangedSubview(leadingContainer)
        centerContainer.addArrangedSubview(inputMessageView)
        centerContainer.addArrangedSubview(trailingContainer)
        centerContainer.layoutMargins = .zero

        trailingContainer.alignment = .center
        trailingContainer.spacing = 0
        trailingContainer.distribution = .equal
        trailingContainer.directionalLayoutMargins = .zero
        trailingContainer.addArrangedSubview(sendButton)
        trailingContainer.addArrangedSubview(cooldownView)
        trailingContainer.addArrangedSubview(confirmButton)

        cooldownView.isHidden = true
        confirmButton.isHidden = true
        if components.isVoiceRecordingEnabled {
            trailingContainer.addArrangedSubview(recordButton)
        }
        trailingContainer.addArrangedSubview(photoButton)
        trailingContainer.addArrangedSubview(stickerButton)

        leadingContainer.axis = .horizontal
        leadingContainer.alignment = .center
        leadingContainer.spacing = 0
        leadingContainer.distribution = .equal
        leadingContainer.directionalLayoutMargins = .zero
        leadingContainer.addArrangedSubview(commandsButton)
        leadingContainer.addArrangedSubview(composerMenuButton)
        leadingContainer.heightAnchor.pin(greaterThanOrEqualToConstant: 46).isActive = true

        dismissButton.widthAnchor.pin(equalToConstant: 24).isActive = true
        dismissButton.heightAnchor.pin(equalToConstant: 24).isActive = true
        dismissButton.trailingAnchor.pin(equalTo: trailingContainer.trailingAnchor).isActive = true
        titleLabel.centerXAnchor.pin(equalTo: centerXAnchor).isActive = true
        titleLabel.pin(anchors: [.top, .bottom], to: headerView)

        [sendButton, confirmButton, recordButton, photoButton, stickerButton]
            .forEach { button in
                button.pin(anchors: [.width], to: 35)
                button.pin(anchors: [.height], to: 46)
            }

        [composerMenuButton, commandsButton]
            .forEach { button in
                button.pin(anchors: [.width], to: 38)
                button.pin(anchors: [.height], to: 38)
            }
    }
}
