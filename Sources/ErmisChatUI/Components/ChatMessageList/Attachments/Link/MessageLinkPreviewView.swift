//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class MessageLinkPreviewView: _Control, UIProvider, RemoteImageDisplayable {
    public var content: MessageLinkAttachment? { didSet { updateContentIfNeeded() } }

    /// Image view showing link's preview image.
    public private(set) lazy var imagePreview = UIImageView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "imagePreview")

    /// Background for `authorLabel`.
    public private(set) lazy var authorBackground = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "authorBackground")

    /// Label showing author of the link.
    public private(set) lazy var authorLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "authorLabel")

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

    /// Constraint for `authorLabel` top anchor.
    open var authorOnImageConstraint: NSLayoutConstraint?

    /// Constraint for `imagePreview`'s height.
    open var imagePreviewHeightConstraint: NSLayoutConstraint?

    public weak var imageDownloadTask: (any Cancellable)?

    public var imageView: UIImageView {
        return imagePreview
    }

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = BaseColor.surfaceContainerHigh
        imagePreview.contentMode = .scaleAspectFill
        imagePreview.layer.cornerRadius = 8
        imagePreview.clipsToBounds = true

        authorBackground.layer.cornerRadius = 15
        authorBackground.layer.maskedCorners = [.layerMaxXMinYCorner]
        authorBackground.clipsToBounds = true
        authorBackground.backgroundColor = theme.colors.surfaceContainerHigh

        authorLabel.font = theme.fonts.body.bold
        authorLabel.adjustsFontForContentSizeCategory = true

        titleLabel.font = theme.fonts.subheadline.bold
        titleLabel.adjustsFontForContentSizeCategory = true

        bodyTextView.backgroundColor = .clear
        bodyTextView.font = theme.fonts.subheadline
        bodyTextView.adjustsFontForContentSizeCategory = true
        bodyTextView.textContainerInset = .zero
        bodyTextView.textContainer.lineFragmentPadding = 0
        bodyTextView.textContainer.maximumNumberOfLines = 3
        bodyTextView.textContainer.lineBreakMode = .byTruncatingTail
    }

    override open func setUp() {
        super.setUp()

        imagePreview.isUserInteractionEnabled = false
        authorBackground.isUserInteractionEnabled = false
        textStack.isUserInteractionEnabled = false

        bodyTextView.isEditable = false
        bodyTextView.isScrollEnabled = false
    }

    override open func setUpUI() {
        super.setUpUI()

        addSubview(imagePreview)
        addSubview(authorBackground)
        addSubview(textStack)

        imagePreview.pin(anchors: [.leading, .top, .trailing], to: self)
        imagePreviewHeightConstraint = imagePreview.heightAnchor.pin(equalTo: imagePreview.widthAnchor, multiplier: 0.5)
        imagePreviewHeightConstraint?.isActive = true

        textStack.addArrangedSubviews([titleLabel, bodyTextView])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.topAnchor.pin(equalToSystemSpacingBelow: imagePreview.bottomAnchor).isActive = true
        textStack.pin(anchors: [.leading, .bottom, .trailing], to: layoutMarginsGuide)

        authorBackground.bottomAnchor.pin(equalTo: imagePreview.bottomAnchor).isActive = true
        imagePreview.trailingAnchor.pin(greaterThanOrEqualToSystemSpacingAfter: authorBackground.trailingAnchor).isActive = true
        authorBackground.embed(authorLabel, insets: NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 12))
        authorLabel.leadingAnchor.pin(equalTo: textStack.leadingAnchor).isActive = true

        authorOnImageConstraint = authorBackground.topAnchor
            .pin(equalTo: topAnchor, constant: -8)
            .with(priority: .ermisLow)

        NSLayoutConstraint.activate([
            authorBackground.leadingAnchor
                .pin(equalTo: textStack.leadingAnchor)
                .with(priority: .ermisLow),
            authorBackground.bottomAnchor
                .pin(equalTo: textStack.topAnchor, constant: -8)
                .with(priority: .ermisLow),
            imagePreview.trailingAnchor
                .pin(greaterThanOrEqualToSystemSpacingAfter: authorBackground.trailingAnchor)
                .with(priority: .ermisLow),
            authorLabel.leadingAnchor
                .pin(equalTo: textStack.leadingAnchor)
                .with(priority: .ermisLow)
        ])

        authorLabel.setContentCompressionResistancePriority(.ermisRequire, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.ermisRequire, for: .vertical)
        bodyTextView.setContentHuggingPriority(.ermisLow, for: .horizontal)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        if content == nil {
            cancelImageLoading()
            imageView.image = nil
            return
        }

        let payload = content?.payload

        let isImageHidden = payload?.previewURL == nil
        let isAuthorHidden = payload?.author == nil

        authorLabel.textColor = tintColor

        loadImage(from: payload?.previewURL)

        imagePreview.isHidden = isImageHidden

        authorLabel.text = payload?.author
        authorLabel.isHidden = isAuthorHidden
        authorBackground.isHidden = isAuthorHidden

        titleLabel.text = payload?.title
        titleLabel.isHidden = payload?.title == nil

        bodyTextView.text = payload?.text
        bodyTextView.isHidden = payload?.text == nil

        imagePreviewHeightConstraint?.isActive = !isImageHidden
        authorOnImageConstraint?.isActive = isImageHidden && !isAuthorHidden

        // If all the data is empty, hide the attachment preview view.
        isHidden = isImageHidden && isAuthorHidden && payload?.title == nil && payload?.text == nil
    }

    override open func tintColorDidChange() {
        super.tintColorDidChange()

        guard UIApplication.shared.applicationState == .active else { return }
        updateContentIfNeeded()
    }

    deinit {
        log.debug("TTT")
    }
}
