//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The delegate used in `LinkAttachmentViewInjector` to communicate user interactions.
@available(iOSApplicationExtension, unavailable)
public protocol LinkPreviewViewDelegate: MessageContentViewDelegate {
    /// Called when the user taps the link preview.
    func didTapOnLinkAttachment(
        _ attachment: MessageLinkAttachment,
        at indexPath: IndexPath?
    )
}

/// View injector for showing link attachments.
@available(iOSApplicationExtension, unavailable)
open class LinkAttachmentViewInjector: CustomCellViewInjector {
    public override var customView: UIView {
        return linkPreviewView
    }

    open private(set) lazy var linkPreviewView = contentView
        .components
        .linkPreviewView
        .init()
        .withoutAutoresizingMaskConstraints

    override open func contentViewDidLayout(options: MessageLayoutOptions) {
        super.contentViewDidLayout(options: options)
        contentView.bubbleView?.clipsToBounds = true
        linkPreviewView.addTarget(self, action: #selector(handleTapOnAttachment), for: .touchUpInside)
    }

    override open func contentViewDidcontentDidChanged() {
        linkPreviewView.content = contentView.content?.linkAttachments.first
    }

    /// Triggered when `attachment` is tapped.
    @objc open func handleTapOnAttachment() {
        guard
            let attachment = linkPreviewView.content
        else { return }
        (contentView.delegate as? LinkPreviewViewDelegate)?
            .didTapOnLinkAttachment(
                attachment,
                at: contentView.indexPath?()
            )
    }

    open override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
        linkPreviewView.content = nil
    }
}
