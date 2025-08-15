//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class MessageLinkPreviewView: _Control, UIProvider, RemoteImageDisplayable, MessageBubbleProvidable {
    public var content: MessageLinkAttachment? { didSet { updateContentIfNeeded() } }

    public private(set) lazy var container = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "container")

    /// Image view showing link's preview image.
    public private(set) lazy var imagePreview = UIImageView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "imagePreview")

    /// Label showing `title`.
    public private(set) lazy var titleLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "titleLabel")

    /// Text view for showing `content`'s `text`.
    public private(set) lazy var bodyTextView = UITextView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "bodyTextView")

    /// `ContainerStackView` for labels with text metadata.
    public private(set) lazy var textStack = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "textStack")

    /// Constraint for `imagePreview`'s height.
    open var imagePreviewHeightConstraint: NSLayoutConstraint?

    public var imageView: UIImageView {
        return imagePreview
    }

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = BaseColor.surfaceContainerHigh
        imagePreview.contentMode = .scaleAspectFill
        imagePreview.layer.cornerRadius = 8
        imagePreview.clipsToBounds = true

        titleLabel.font = theme.fonts.subheadline.bold

        bodyTextView.backgroundColor = .clear
        bodyTextView.font = theme.fonts.body
        bodyTextView.adjustsFontForContentSizeCategory = true
        bodyTextView.textContainerInset = .zero
        bodyTextView.textContainer.lineFragmentPadding = 0
        bodyTextView.textContainer.maximumNumberOfLines = 3
        bodyTextView.textContainer.lineBreakMode = .byTruncatingTail
    }

    override open func setUp() {
        super.setUp()
        titleLabel.numberOfLines = 2
        imagePreview.isUserInteractionEnabled = false
        textStack.isUserInteractionEnabled = false

        bodyTextView.isEditable = false
        bodyTextView.isScrollEnabled = false
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(container)

        container.addArrangedSubviews([
            imageView,
            textStack
        ])
        container.axis = .vertical
        container.alignment = .fill
        container.spacing = 12
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = .init(top: 12, left: 12, bottom: 12, right: 12)

        imagePreviewHeightConstraint = imagePreview.heightAnchor.pin(equalTo: imagePreview.widthAnchor, multiplier: 0.5)
        imagePreviewHeightConstraint?.isActive = true

        textStack.addArrangedSubviews([titleLabel, bodyTextView])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        titleLabel.setContentCompressionResistancePriority(.ermisRequire, for: .vertical)
        bodyTextView.setContentHuggingPriority(.ermisLow, for: .horizontal)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        if content == nil {
            imageView.image = nil
            return
        }

        let payload = content?.payload

        let isImageHidden = payload?.previewURL == nil

        loadImage(from: payload?.previewURL)

        imagePreview.isHidden = isImageHidden

        titleLabel.text = payload?.title
        titleLabel.isHidden = titleLabel.text.isEmptyOrNil

        bodyTextView.text = payload?.text
        bodyTextView.isHidden = bodyTextView.text.isEmptyOrNil

        imagePreviewHeightConstraint?.isActive = !isImageHidden
        // If all the data is empty, hide the attachment preview view.
        let noPreview = isImageHidden && titleLabel.isHidden && bodyTextView.isHidden
        if noPreview {
            titleLabel.text = L10n.noPreviewAvailable
            titleLabel.isHidden = false
        }
    }

    override open func tintColorDidChange() {
        super.tintColorDidChange()

        guard UIApplication.shared.applicationState == .active else { return }
        updateContentIfNeeded()
    }
}
