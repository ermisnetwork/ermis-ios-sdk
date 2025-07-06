//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view to input content of a message.
open class InputMessageView: _View, ComponentsProvider, ThemeProvider {
    /// The content of the view
    public struct Content {
        /// The message that is being quoted.
        var quotingMessage: ChatMessage?
        /// The command that the message produces.
        var command: Command?
        /// The channel which the new message will belong to.
        var channel: Channel?
    }

    /// The content of the view
    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The main container stack view that layouts all the message input content views.
    public private(set) lazy var container = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "container")

    /// A view that displays the quoted message that the new message is replying.
    public private(set) lazy var quotedMessageView = components
        .quotedMessageView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "quotedMessageView")

    /// A view that displays the attachments of the new message.
    /// This is view from separate AttachmentsVC and will be injected by the ComposerViewController.
    public private(set) lazy var attachmentsViewContainer = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "attachmentsViewContainer")

    /// The container stack view that layouts the command label, text view and the clean button.
    public private(set) lazy var inputTextContainer = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "inputTextContainer")

    /// The input text view to type a new message or command.
    public private(set) lazy var textView: InputTextView = components
        .inputTextView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "textView")

    /// The command label that display the command info if a new command is being typed.
    public private(set) lazy var commandLabelView: CommandLabelView = components
        .commandLabelView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "commandLabelView")

    /// A button to clear the current typing information.
    public private(set) lazy var clearButton: UIButton = components
        .closeButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "clearButton")

    override open func setUpTheme() {
        super.setUpTheme()

        let closeTransparentImage = theme.icons.closeCircleTransparent
            .tinted(with: theme.colors.disabledColorForColor(
                theme.colors.text
            ))
        clearButton.setImage(closeTransparentImage, for: .normal)

        container.clipsToBounds = true
        container.layer.cornerRadius = 19
        container.layer.borderWidth = 1
        container.layer.borderColor = theme.colors.outline.cgColor
    }

    override open func setUpUI() {
        addSubview(container)
        container.pin(to: layoutMarginsGuide)
        directionalLayoutMargins = .zero

        container.isLayoutMarginsRelativeArrangement = true
        container.directionalLayoutMargins = .zero
        container.axis = .vertical
        container.alignment = .fill
        container.distribution = .natural
        container.spacing = 0
        container.addArrangedSubview(quotedMessageView)
        container.addArrangedSubview(attachmentsViewContainer)
        container.addArrangedSubview(inputTextContainer)
        quotedMessageView.isHidden = true
        attachmentsViewContainer.isHidden = true

        inputTextContainer.isLayoutMarginsRelativeArrangement = true
        inputTextContainer.alignment = .center
        inputTextContainer.spacing = 4
        inputTextContainer.directionalLayoutMargins = .init(top: 0, leading: 6, bottom: 0, trailing: 6)
        inputTextContainer.addArrangedSubview(commandLabelView)
        inputTextContainer.addArrangedSubview(textView)
        inputTextContainer.addArrangedSubview(clearButton)

        commandLabelView.setContentCompressionResistancePriority(.ermisRequire, for: .horizontal)
        textView.setContentCompressionResistancePriority(.ermisLow, for: .horizontal)
        textView.preservesSuperviewLayoutMargins = false

        NSLayoutConstraint.activate([
            clearButton.heightAnchor.pin(equalToConstant: 24),
            clearButton.widthAnchor.pin(equalTo: clearButton.heightAnchor, multiplier: 1)
        ])
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        guard let content = self.content else { return }

        if let quotingMessage = content.quotingMessage {
            quotedMessageView.content = .init(
                message: quotingMessage,
                avatarAlignment: quotingMessage.isSentByCurrentUser ? .trailing : .leading,
                isParentMessageSentByCurrentUser: false,
                channel: content.channel
            )
        }

        if let command = content.command {
            commandLabelView.content = command
        }

        Animate {
            self.quotedMessageView.isHidden = content.quotingMessage == nil
            self.commandLabelView.isHidden = content.command == nil
            self.clearButton.isHidden = content.command == nil
        }
    }
}
