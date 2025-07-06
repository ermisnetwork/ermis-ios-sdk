//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

open class EditedMessageListItemView: _View, UIProvider, PreviewMessageProvider {
    /// Shows edited message text content.
    public private(set) lazy var textView = createTextView()

    /// Shows edited time.
    public private(set) lazy var timestampLabel = createTimestampLabel()

    /// A formatter that converts the message timestamp to textual representation.
    public lazy var timestampFormatter: MessageTimestampFormatter = formatters.messageTimestamp

    public var content: MessageEditHistory? {
        didSet {
            updateContentIfNeeded()
        }
    }

    // MARK: - Setup
    open override func setUp() {

    }

    open override func setUpUI() {
        addSubviews([
            textView,
            timestampLabel,
        ])

        textView.pin(anchors: [.top, .leading], to: self, contant: 16)
        textView.pin(anchors: [.centerX], to: self)
        timestampLabel.topAnchor.pin(equalTo: textView.bottomAnchor, constant: 8).isActive = true

        timestampLabel.pin(anchors: [.leading, .trailing], to: textView)
        timestampLabel.pin(anchors: [.bottom], to: self, contant: -16)
    }

    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        textView.textColor = theme.colors.text
        textView.font = theme.fonts.body.bold
        timestampLabel.textColor = theme.colors.subtitleText
        timestampLabel.font = theme.fonts.footnote
    }

    open override func contentDidChanged() {
        guard let content else {
            textView.text = ""
            timestampLabel.text = ""
            return
        }
        textView.text = content.text
        timestampLabel.text = timestampFormatter.format(content.createdAt)
    }
    // MARK: - Create UI
    open func createTextView() -> UITextView {
        let textView = OnlyLinkTappableTextView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "textView")
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .init(top: 0, left: 0, bottom: 0, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = theme.fonts.body
        textView.textContainer.maximumNumberOfLines = 2
        return textView
    }

    /// Create `timeStampLabel` when called for the first time.
    /// - Returns: The `timeStampLabel` subview.
    open func createTimestampLabel() -> UILabel {
        let label = UILabel()
            .withAdjustingFontForContentSizeCategory
            .withBidirectionalLanguagesSupport
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "timeStampLabel")
        return label
    }
}

// MARK: - Create UI
extension EditedMessageListItemView {
    private func createLeadingStack() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    private func createCenterStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.alignment = .leading
        containerStackView.axis = .vertical
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    private func createTrailingStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }
}
