//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays the link metadata when typing links in the composer.
open class ComposerLinkPreviewView: _View, UIProvider, RemoteImageDisplayable {
    /// The content of the composer link preview view.
    public struct Content {
        public var linkAttachmentPayload: LinkAttachmentPayload

        public init(linkAttachmentPayload: LinkAttachmentPayload) {
            self.linkAttachmentPayload = linkAttachmentPayload
        }
    }

    /// The content of the composer link preview view.
    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// A closure that is triggered whenever the `closeButton` is tapped.
    public var onClose: (() -> Void)?

    /// The main stack view that layouts the image preview, text content and the close button.
    open private(set) lazy var mainStackView = UIStackView()
        .withoutAutoresizingMaskConstraints

    /// An image view that displays the link image preview, or the link icon in case no image found.
    open private(set) lazy var imagePreviewView = UIImageView()
        .withoutAutoresizingMaskConstraints

    /// The stack view that holds the divider, title and description of the link.
    open private(set) lazy var textContainerStackView = UIStackView()
        .withoutAutoresizingMaskConstraints

    /// The divider between the image and the text content.
    open private(set) lazy var divider = UIView()
        .withoutAutoresizingMaskConstraints

    /// The stack view that holds the text content of the link.
    open private(set) lazy var textStackView = UIStackView()
        .withoutAutoresizingMaskConstraints

    /// The label that displays the title of the link.
    open private(set) lazy var titleLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory

    /// The label that displays the description of the link.
    open private(set) lazy var descriptionLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory

    /// The button that closes the link preview view.
    open private(set) lazy var closeButton = UIButton()
        .withoutAutoresizingMaskConstraints

    /// The width of the divider.
    open var dividerWidth: CGFloat {
        2
    }

    /// The minimum height of the divider.
    open var minimumDividerHeight: CGFloat {
        32
    }

    public var imageView: UIImageView {
        return imagePreviewView
    }

    override open func setUp() {
        super.setUp()

        closeButton.addTarget(self, action: #selector(didTapCloseButton), for: .touchUpInside)
    }

    override open func setUpTheme() {
        super.setUpTheme()

        imagePreviewView.clipsToBounds = true

        titleLabel.font = theme.fonts.footnote.bold
        descriptionLabel.font = theme.fonts.footnote

        backgroundColor = theme.colors.surface
        closeButton.setImage(theme.icons.discard, for: .normal)
        closeButton.tintColor = theme.colors.text
        divider.backgroundColor = theme.colors.primary
    }

    override open func setUpUI() {
        super.setUpUI()
        
        mainStackView.axis = .horizontal
        mainStackView.distribution = .fill
        mainStackView.alignment = .center
        mainStackView.spacing = 8

        textContainerStackView.axis = .horizontal
        textContainerStackView.spacing = 6

        textStackView.axis = .vertical
        textStackView.spacing = 3

        embed(mainStackView)
        mainStackView.addArrangedSubview(imagePreviewView)
        mainStackView.addArrangedSubview(textContainerStackView)
        textContainerStackView.addArrangedSubview(divider)
        textContainerStackView.addArrangedSubview(textStackView)
        mainStackView.addArrangedSubview(textContainerStackView)
        textStackView.addArrangedSubview(titleLabel)
        textStackView.addArrangedSubview(descriptionLabel)
        mainStackView.addArrangedSubview(closeButton)

        NSLayoutConstraint.activate([
            divider.widthAnchor.pin(equalToConstant: dividerWidth),
            divider.heightAnchor.pin(greaterThanOrEqualToConstant: minimumDividerHeight),
            imagePreviewView.widthAnchor.pin(equalToConstant: 35),
            imagePreviewView.heightAnchor.pin(equalToConstant: 35),
            closeButton.widthAnchor.pin(equalToConstant: 28),
            closeButton.heightAnchor.pin(equalToConstant: 28)
        ])
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        guard let content = self.content else {
            return
        }

        titleLabel.text = content.linkAttachmentPayload.title ?? content.linkAttachmentPayload.originalURL.absoluteString
       
        descriptionLabel.text = content.linkAttachmentPayload.text
        descriptionLabel.isHidden = content.linkAttachmentPayload.text == nil

        if let imageUrl = content.linkAttachmentPayload.previewURL {
            imagePreviewView.contentMode = .scaleAspectFill
            loadImage(from: imageUrl)
        } else {
            imagePreviewView.contentMode = .center
            imagePreviewView.setImage(theme.icons.link)
        }
    }

    @objc func didTapCloseButton() {
        onClose?()
    }
}
