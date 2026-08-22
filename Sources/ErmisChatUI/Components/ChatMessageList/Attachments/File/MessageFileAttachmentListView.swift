//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// View which holds one or more file attachment views in a message or composer attachment view
open class MessageFileAttachmentListView: _View, ComponentsProvider {
    /// Content of the attachment list - Array of `MessageFileAttachment`
    open var content: [MessageFileAttachment] = [] {
        didSet { updateContentIfNeeded() }
    }

    /// Closure which notifies when the user tapped the attachment.
    open var didTapOnAttachment: ((MessageFileAttachment) -> Void)?

    /// Closure which notifies when the user tapped an attachment action. (Ex: Retry)
    open var didTapActionOnAttachment: ((MessageFileAttachment) -> Void)?

    /// Container which holds one or multiple attachment views in self.
    open private(set) lazy var containerStackView: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "containerStackView")

    override open func setUpUI() {
        directionalLayoutMargins = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        addSubview(containerStackView)
        containerStackView.pin(to: layoutMarginsGuide)

        containerStackView.axis = .vertical
        containerStackView.spacing = 4
    }

    override open func contentDidChanged() {
        containerStackView.subviews.forEach { $0.removeFromSuperview() }
        
        content.forEach { attachment in
            let item = components.fileAttachmentView.init()
            item.didTapOnAttachment = { [weak self] in self?.didTapOnAttachment?($0) }
            item.didTapActionOnAttachment = { [weak self] in self?.didTapActionOnAttachment?($0) }
            item.content = attachment
            containerStackView.addArrangedSubview(item)
        }
    }

    /// Applies process-scoped download state to the matching visible item without mutating the
    /// immutable message attachment model or conflating download progress with upload state.
    open func setDownloadPresentation(
        _ presentation: FileAttachmentDownloadPresentation,
        for attachmentId: AttachmentId
    ) {
        containerStackView.subviews
            .compactMap { $0 as? ItemView }
            .first(where: { $0.content?.id == attachmentId })?
            .downloadPresentation = presentation
    }
}
