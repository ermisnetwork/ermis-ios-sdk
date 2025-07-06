//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The delegate used `FileAttachmentViewInjector` to communicate user interactions.
public protocol FileActionContentViewDelegate: MessageContentViewDelegate {
    /// Called when the user taps on the attachment.
    func didTapOnAttachment(_ attachment: MessageFileAttachment, at indexPath: IndexPath?)
    
    /// Called when the user taps on the action of the attachment. (Ex: Retry)
    func didTapActionOnAttachment(_ attachment: MessageFileAttachment, at indexPath: IndexPath?)
}

public class FilesAttachmentViewInjector: CustomCellViewInjector {
    public override var customView: UIView {
        return fileAttachmentView
    }

    open lazy var fileAttachmentView: MessageFileAttachmentListView = {
        let attachmentListView = contentView
            .components
            .fileAttachmentListView
            .init()

        attachmentListView.didTapOnAttachment = { [weak self] attachment in
            guard
                let delegate = self?.contentView.delegate as? FileActionContentViewDelegate
            else { return }
            delegate.didTapOnAttachment(attachment, at: self?.contentView.indexPath?())
        }

        attachmentListView.didTapActionOnAttachment = { [weak self] attachment in
            guard
                let delegate = self?.contentView.delegate as? FileActionContentViewDelegate
            else { return }
            delegate.didTapActionOnAttachment(attachment, at: self?.contentView.indexPath?())
        }

        return attachmentListView.withoutAutoresizingMaskConstraints
    }()

    override open func contentViewDidLayout(options: MessageLayoutOptions) {
        super.contentViewDidLayout(options: options)
    }

    override open func contentViewDidcontentDidChanged() {
        fileAttachmentView.content = fileAttachments
    }

    public override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
        fileAttachmentView.content = []
    }
}

public extension FilesAttachmentViewInjector {
    var fileAttachments: [MessageFileAttachment] {
        if fileAttachmentView.components.isVoiceRecordingEnabled {
            return contentView.content?.fileAttachments ?? []
        } else {
            let fileAttachments = contentView.content?.fileAttachments ?? []
            let voiceRecordingAttachments = (contentView.content?.voiceRecordingAttachments ?? [])
                .compactMap { $0.asAttachment(payloadType: FileAttachmentPayload.self) }
            return fileAttachments + voiceRecordingAttachments
        }
    }
}
