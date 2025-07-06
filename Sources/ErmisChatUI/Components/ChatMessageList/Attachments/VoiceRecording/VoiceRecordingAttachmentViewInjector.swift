//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The delegate that will be assigned on an AudioView and will be responsible to handle user interactions
/// from the view.
public protocol VoiceRecordingAttachmentPresentationViewDelegate: MessageContentViewDelegate {
    /// Called when the user taps on the play button.
    func voiceRecordingAttachmentPresentationViewConnect(
        delegate: AudioPlayingDelegate
    )

    /// Called when the user taps on the play button.
    func voiceRecordingAttachmentPresentationViewBeginPayback(
        _ attachment: MessageVoiceRecordingAttachment
    )

    /// Called when the user taps on the pause button.
    func voiceRecordingAttachmentPresentationViewPausePayback()

    /// Called when the user taps on the playback rate button.
    func voiceRecordingAttachmentPresentationViewUpdatePlaybackRate(
        _ audioPlaybackRate: AudioPlaybackRate
    )

    /// Called when the user scrubs the progress view.
    func voiceRecordingAttachmentPresentationViewSeek(to timeInterval: TimeInterval)
}

public class VoiceRecordingAttachmentViewInjector: CustomCellViewInjector {
    public override var customView: UIView {
        return voiceRecordingAttachmentView
    }

    open lazy var voiceRecordingAttachmentView: MessageVoiceRecordingAttachmentListView = {
        let attachmentListView = contentView
            .components
            .voiceRecordingAttachmentListView
            .init()

        attachmentListView.playbackDelegate = contentView.delegate as? VoiceRecordingAttachmentPresentationViewDelegate

        return attachmentListView.withoutAutoresizingMaskConstraints
    }()

    override open func contentViewDidLayout(options: MessageLayoutOptions) {
        super.contentViewDidLayout(options: options)
    }

    override open func contentViewDidcontentDidChanged() {
        voiceRecordingAttachmentView.content = voiceRecordingAttachments
    }

    public override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
        voiceRecordingAttachmentView.content = []
    }
}

private extension VoiceRecordingAttachmentViewInjector {
    var voiceRecordingAttachments: [MessageVoiceRecordingAttachment] {
        contentView.content?.voiceRecordingAttachments ?? []
    }
}
