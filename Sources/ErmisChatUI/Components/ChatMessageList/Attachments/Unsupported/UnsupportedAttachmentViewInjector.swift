//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// ErmisChat's native attachment types.
internal extension AttachmentType {
    static var knownTypes: Set<AttachmentType> {
        [.image, .file, .video, .audio, .voiceRecording, .linkPreview]
    }
}

/// Returns all the non-native attachments.
internal extension ChatMessage {
    var unsupportedAttachments: [AnyMessageAttachment] {
        allAttachments.filter {
            AttachmentType.knownTypes.contains($0.type) == false
        }
    }
}

/// The injector for unknown/unsupported attachments.
///
/// By default it renders unsupported attachments as file attachments.
public class UnsupportedAttachmentViewInjector: CustomCellViewInjector {
    public lazy var filesAttachmentInjector = FilesAttachmentViewInjector(self.contentView)

    override open func contentViewDidLayout(options: MessageLayoutOptions) {
        filesAttachmentInjector.contentViewDidLayout(options: options)
        filesAttachmentInjector.fileAttachmentView.didTapOnAttachment = nil
    }

    override open func contentViewContentDidChanged() {
        let unsupportedAttachments = contentView.content?.unsupportedAttachments ?? []
        let unsupportedFileAttachments = unsupportedAttachments.map {
            MessageFileAttachment(
                id: $0.id,
                type: $0.type,
                payload: FileAttachmentPayload(
                    title: nil,
                    assetRemoteURL: $0.uploadingState?.localFileURL ?? URL(string: "unknown")!,
                    file: .init(type: .unknown, size: 0, mimeType: nil)
                ),
                thumbnailData: $0.thumbnailData,
                uploadingState: $0.uploadingState
            )
        }

        filesAttachmentInjector.fileAttachmentView.content = unsupportedFileAttachments
    }

    public override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
        filesAttachmentInjector.fileAttachmentView.content = []
    }
}
