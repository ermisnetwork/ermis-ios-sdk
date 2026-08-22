//
// Copyright 2026 Ermis Inc.
//

import ErmisChat
@testable import ErmisChatUI
import Foundation
import XCTest

@MainActor
final class VoiceRecordingAttachmentItemViewTests: XCTestCase {
    func testEmptyWaveformUsesVisiblePresentationFallback() {
        let waveform = MessageVoiceRecordingAttachmentListView.ItemView.displayWaveform([])

        XCTAssertFalse(waveform.isEmpty)
        XCTAssertTrue(waveform.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    func testPresenterSubscribesWhenDelegateIsAssignedAndTracksResolvedE2eePlayback() throws {
        let opaqueURL = try XCTUnwrap(URL(string: "ermis-e2ee-attachment://asset/original"))
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice.aac")
        let attachment = try makeAttachment(url: opaqueURL)
        let player = AudioPlayerMock()
        let delegate = PlaybackDelegateMock(audioPlayer: player)
        let view = MessageVoiceRecordingAttachmentListView.ItemView()
        view.content = attachment

        view.presenter.delegate = delegate
        delegate.activeAttachmentId = attachment.id

        XCTAssertEqual(player.subscriberCount, 1)

        var playingContext = AudioPlaybackContext.notLoaded
        playingContext.assetLocation = localURL
        playingContext.duration = 4
        playingContext.currentTime = 1
        playingContext.state = .playing
        playingContext.rate = .normal
        player.publish(playingContext)

        XCTAssertTrue(view.playPauseButton.isSelected)

        var pausedContext = playingContext
        pausedContext.state = .paused
        pausedContext.rate = .zero
        player.publish(pausedContext)

        XCTAssertFalse(view.playPauseButton.isSelected)
    }

    func testReadyVoiceControlsStayInsideCompactIncomingBubble() throws {
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 60))
        let view = MessageVoiceRecordingAttachmentListView.ItemView()
        view.frame = hostView.bounds
        hostView.addSubview(view)
        view.content = try makeAttachment(
            url: XCTUnwrap(URL(string: "ermis-e2ee-attachment://asset/original"))
        )

        hostView.layoutIfNeeded()
        view.mainContainerStackView.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(
            view.playPauseButton.convert(view.playPauseButton.bounds, to: view).minX,
            view.directionalLayoutMargins.leading
        )
        XCTAssertLessThanOrEqual(
            view.durationLabel.convert(view.durationLabel.bounds, to: view).maxX,
            view.bounds.width - view.directionalLayoutMargins.trailing
        )
        XCTAssertGreaterThanOrEqual(view.waveformView.bounds.width, 80)
        XCTAssertFalse(view.durationLabel.isHidden)
        XCTAssertEqual(view.durationLabel.text, DefaultVideoDurationFormatter().format(4))
    }

    func testVideoPreviewShowsManifestDurationBeforePlaybackStarts() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try Data([1, 2, 3, 4]).write(to: sourceURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try AttachmentFile(url: sourceURL, fileSize: 4)
        var payload = VideoAttachmentPayload(
            title: "clip.mov",
            videoRemoteURL: try XCTUnwrap(URL(string: "ermis-e2ee-attachment://asset/original")),
            file: file
        )
        payload.duration = 24
        let attachment = MessageVideoAttachment(
            id: AttachmentId(
                cid: ChannelId(type: .messaging, id: "video-ui"),
                messageId: "message-id",
                index: 0
            ),
            type: .video,
            payload: payload,
            thumbnailData: nil,
            uploadingState: nil
        )

        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let preview = VideoAttachmentGalleryPreview(frame: hostView.bounds)
        hostView.addSubview(preview)
        preview.content = attachment
        hostView.layoutIfNeeded()

        XCTAssertFalse(preview.durationLabel.isHidden)
        XCTAssertEqual(preview.durationLabel.text, DefaultVideoDurationFormatter().format(24))
        XCTAssertTrue(preview.loadingIndicator.isHidden)
        XCTAssertNil(preview.imageView.image)
        XCTAssertNotNil(preview.imageView.backgroundColor)
        XCTAssertEqual(preview.imageView.layer.cornerRadius, 12)
        XCTAssertEqual(preview.imageView.layer.borderWidth, 1)
        XCTAssertNotNil(preview.imageView.layer.borderColor)
        XCTAssertTrue(preview.playButton.isVisible)
    }

    private func makeAttachment(url: URL) throws -> MessageVoiceRecordingAttachment {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("aac")
        try Data([1, 2, 3, 4]).write(to: sourceURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceURL) }
        let file = try AttachmentFile(url: sourceURL, fileSize: 4)
        return MessageVoiceRecordingAttachment(
            id: AttachmentId(
                cid: ChannelId(type: .messaging, id: "voice-ui"),
                messageId: "message-id",
                index: 0
            ),
            type: .voiceRecording,
            payload: VoiceRecordingAttachmentPayload(
                title: "voice.aac",
                voiceRecordingRemoteURL: url,
                file: file,
                duration: 4,
                waveformData: []
            ),
            thumbnailData: nil,
            uploadingState: nil
        )
    }
}

@MainActor
private final class PlaybackDelegateMock: VoiceRecordingAttachmentPresentationViewDelegate {
    let audioPlayer: AudioPlayerMock
    var activeAttachmentId: AttachmentId?

    init(audioPlayer: AudioPlayerMock) {
        self.audioPlayer = audioPlayer
    }

    func voiceRecordingAttachmentPresentationViewConnect(delegate: AudioPlayingDelegate) {
        audioPlayer.subscribe(delegate)
    }

    func voiceRecordingAttachmentPresentationViewBeginPayback(
        _ attachment: MessageVoiceRecordingAttachment
    ) {
        activeAttachmentId = attachment.id
    }

    func voiceRecordingAttachmentPresentationViewPausePayback() {}

    func voiceRecordingAttachmentPresentationViewUpdatePlaybackRate(
        _ audioPlaybackRate: AudioPlaybackRate
    ) {}

    func voiceRecordingAttachmentPresentationViewSeek(to timeInterval: TimeInterval) {}

    func voiceRecordingAttachmentPresentationView(
        _ attachment: MessageVoiceRecordingAttachment,
        matchesPlaybackURL playbackURL: URL?
    ) -> Bool {
        activeAttachmentId == attachment.id
    }

    func messageContentViewDidTapOnErrorIndicator(_ indexPath: IndexPath?) {}
    func messageContentViewDidTapOnThread(_ indexPath: IndexPath?) {}
    func messageContentViewDidTapOnQuotedMessage(_ quotedMessage: ChatMessage) {}
    func messageContentViewDidTapOnAvatarView(_ indexPath: IndexPath?) {}
    func messageContentViewDidTapOnReactionsView(_ indexPath: IndexPath?) {}
    func messageContentViewDidTapAtShowEditedHistory(_ indexPath: IndexPath?) {}
}

@MainActor
private final class AudioPlayerMock: AudioPlaying {
    private var subscribers: [AudioPlayingDelegate] = []
    var subscriberCount: Int { subscribers.count }

    required init() {}

    func subscribe(_ subscriber: AudioPlayingDelegate) {
        subscribers.append(subscriber)
        subscriber.audioPlayer(self, didUpdateContext: .notLoaded)
    }

    func publish(_ context: AudioPlaybackContext) {
        subscribers.forEach { $0.audioPlayer(self, didUpdateContext: context) }
    }

    func loadAsset(from url: URL) {}
    func play() {}
    func pause() {}
    func stop() {}
    func updateRate(_ newRate: AudioPlaybackRate) {}
    func seek(to time: TimeInterval) {}
}
