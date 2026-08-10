//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

extension MessageVoiceRecordingAttachmentListView {
    /// A view that renders a VoiceRecording attachment and allows playback and interaction.
    ///
    /// High level overview of the ItemView layout:
    /// ```
    /// |-----------------------------------------------------------------------|
    /// |                 | fileNameLabel           |                           |
    /// | playPauseButton | ------------------------| fileIconAndPlaybackRate   |
    /// |                 | bottomContainerStackView|                           |
    /// |-----------------------------------------------------------------------|
    /// ```
    open class ItemView: _View, UIProvider, MessageBubbleProvidable {
        /// A neutral visual fallback for Web/legacy voice messages that do not contain waveform
        /// samples. It is presentation-only and is never written back into authenticated metadata.
        static let fallbackWaveform: [Float] = [
            0.24, 0.42, 0.68, 0.36, 0.78, 0.52, 0.88, 0.44,
            0.72, 0.34, 0.62, 0.82, 0.48, 0.70, 0.38, 0.58,
            0.76, 0.46, 0.66, 0.32, 0.54, 0.80, 0.40, 0.64
        ]

        // MARK: - Properties

        /// Content of the attachment `MessageFileAttachment`
        public var content: MessageVoiceRecordingAttachment? {
            didSet { updateContentIfNeeded() }
        }

        // MARK: - Configuration Properties

        /// The Presenter responsible for all interaction and event handling.
        internal lazy var presenter: ItemViewPresenter = .init(self)

        /// The provider that will be asked to provide the index of the content related to the other attachments
        /// in the same `ChatMessage`. The index then will be used to create an name for UI.
        open var indexProvider: (() -> Int)?

        // MARK: - UI Components

        open private(set) lazy var mainContainerStackView: UIStackView = .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "mainContainerStackView")

        /// The play/pause button that allows the user to control the playback.
        open private(set) lazy var playPauseButton: PlayPauseButton = .init()
            .withoutAutoresizingMaskConstraints

        /// A stack that contains by default the file name and the size of the file.
        open private(set) lazy var centerContainerStackView: UIStackView = .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "centerContainerStackView")

        /// Label which shows name of the file, usually with extension (file.pdf)
        open private(set) lazy var fileNameLabel = UILabel()
            .withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAdjustingFontForContentSizeCategory
            .withAccessibilityIdentifier(identifier: "fileNameLabel")

        /// Stack containing loading indicator and label with fileSize.
        open private(set) lazy var bottomContainerStackView: UIStackView = .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "informationStack")

        /// Animated indicator showing progress of uploading of a file.
        open private(set) lazy var loadingIndicator = components
            .loadingIndicator
            .init()
            .withoutAutoresizingMaskConstraints

        /// Label indicating size of the file.
        open private(set) lazy var fileSizeLabel = UILabel()
            .withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAdjustingFontForContentSizeCategory
            .withAccessibilityIdentifier(identifier: "fileSizeLabel")

        /// The clampedView that contains the playbackLoadingIndicator and the durationLabel.
        open private(set) lazy var playbackLoadingClampedView: ClampedView = .init()
            .withoutAutoresizingMaskConstraints

        /// Animated indicator showing progress of buffering an audio file.
        open private(set) lazy var playbackLoadingIndicator = components
            .loadingIndicator
            .init()
            .withoutAutoresizingMaskConstraints

        /// The label that shows the duration of an audio file/the current time of the playback.
        open private(set) lazy var durationLabel = UILabel()
            .withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAdjustingFontForContentSizeCategory
            .withAccessibilityIdentifier(identifier: "durationLabel")

        /// The view that shows a waveform visualisation of the audio file.
        open private(set) lazy var waveformView = WaveformView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "waveform")

        /// The clampedView that contains the fileIcon and the playbackRate button
        open private(set) lazy var fileIconAndPlaybackRateClampedView: ClampedView = .init()
            .withoutAutoresizingMaskConstraints

        /// The imageView showing the file related icon.
        open private(set) lazy var fileIconImageView = UIImageView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "fileIconImageView")

        /// The button that the user can use to set the playback's rate.
        open private(set) lazy var playbackRateButton: PillButton = .init()
            .withoutAutoresizingMaskConstraints

        // MARK: - UI Lifecycle

        override open func setUp() {
            super.setUp()
            presenter.setUp()
        }

        override open func setUpUI() {
            super.setUpUI()

            playbackLoadingClampedView.axis = .vertical
            playbackLoadingClampedView.addArrangedSubview(playbackLoadingIndicator)
            playbackLoadingClampedView.addArrangedSubview(durationLabel)

            fileIconAndPlaybackRateClampedView.addArrangedSubview(fileIconImageView)
            fileIconAndPlaybackRateClampedView.addArrangedSubview(playbackRateButton)

            bottomContainerStackView.axis = .horizontal
            bottomContainerStackView.spacing = 4
            bottomContainerStackView.alignment = .center
            [loadingIndicator, fileSizeLabel, waveformView, playbackLoadingClampedView]
                .forEach { bottomContainerStackView.addArrangedSubview($0) }

            centerContainerStackView.axis = .vertical
            centerContainerStackView.spacing = 8
            centerContainerStackView.alignment = .fill
            [fileNameLabel, bottomContainerStackView]
                .forEach { centerContainerStackView.addArrangedSubview($0) }

            addSubview(mainContainerStackView)
            mainContainerStackView.axis = .horizontal
            mainContainerStackView.spacing = 8
            mainContainerStackView.alignment = .center
            mainContainerStackView.pin(to: layoutMarginsGuide)

            [playPauseButton, centerContainerStackView, fileIconAndPlaybackRateClampedView]
                .forEach { mainContainerStackView.addArrangedSubview($0) }

            durationLabel.setContentHuggingPriority(.ermisRequire, for: .vertical)
            durationLabel.setContentHuggingPriority(.ermisRequire, for: .horizontal)
            waveformView.setContentHuggingPriority(.ermisLow, for: .vertical)
            waveformView.setContentCompressionResistancePriority(.ermisLow, for: .horizontal)
            fileIconImageView.setContentHuggingPriority(.ermisRequire, for: .horizontal)

            let preferredWaveformWidth = waveformView.widthAnchor.constraint(equalToConstant: 168)
            preferredWaveformWidth.priority = .defaultHigh

            NSLayoutConstraint.activate([
                preferredWaveformWidth,
                waveformView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
                waveformView.heightAnchor.constraint(equalToConstant: 36),
                durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38)
            ])
        }

        override open func setUpTheme() {
            super.setUpTheme()

            backgroundColor = theme.colors.surfaceContainer
            layer.cornerRadius = 12
            layer.masksToBounds = true
            layer.borderWidth = 1
            layer.borderColor = theme.colors.outline.cgColor

            fileSizeLabel.textColor = theme.colors.subtitleText
            fileSizeLabel.font = theme.fonts.subheadline.bold

            fileNameLabel.font = theme.fonts.body.bold
            fileNameLabel.lineBreakMode = .byTruncatingMiddle

            fileIconImageView.contentMode = .center
            fileIconImageView.image = theme.icons.fileAac

            durationLabel.textColor = theme.colors.subTitleTextLow
            durationLabel.font = .monospacedDigitSystemFont(
                ofSize: theme.fonts.caption1.pointSize, weight: .medium
            )

            playbackRateButton.setTitleColor(theme.colors.black, for: .normal)
            playbackRateButton.titleLabel?.font = theme.fonts.footnote
        }

        override open func contentDidChanged() {
            super.contentDidChanged()

            fileNameLabel.text = content.map { content in
                formatters.audioRecordingNameFormatter.title(
                    forItemAtURL: content.voiceRecordingURL,
                    index: indexProvider?() ?? 0
                )
            }

            switch content?.uploadingState?.state {
            case .uploaded:
                fileSizeLabel.text = content?.payload.file.sizeString
            case .uploadingFailed:
                fileSizeLabel.text = L10n.Message.Sending.attachmentUploadingFailed
            default:
                fileSizeLabel.text = content?.uploadingState?.fileUploadingProgress
            }

            switch content?.uploadingState?.state {
            case .pendingUpload, .uploading:
                loadingIndicator.isVisible = true
            default:
                loadingIndicator.isVisible = false
            }

            switch content?.uploadingState?.state {
            case .uploadingFailed:
                fileIconImageView.image = theme.fileAttachmentActionIcon(for: .uploadingFailed)
            default:
                fileIconImageView.image = theme.icons.fileAac
            }

            guard
                let content = content,
                content.uploadingState?.state == .uploaded || content.uploadingState == nil
            else {
                fileNameLabel.isHidden = false
                playPauseButton.isHidden = true
                durationLabel.isHidden = true
                fileSizeLabel.isHidden = false
                playbackRateButton.isHidden = true
                waveformView.isHidden = true
                playbackLoadingClampedView.isHidden = true
                return
            }

            fileNameLabel.isHidden = true
            playPauseButton.isHidden = false
            durationLabel.isHidden = false
            fileSizeLabel.isHidden = true
            waveformView.isHidden = false
            playbackLoadingClampedView.isHidden = false
            playbackLoadingIndicator.isHidden = true
            fileIconAndPlaybackRateClampedView.isHidden = true

            // The manifest already carries the authenticated voice duration. Show it before the
            // audio player is first loaded so an idle E2EE voice bubble has the same information
            // as a standard one. Playback updates below may replace this with the current time.
            durationLabel.text = formatters.videoDuration.format(content.duration ?? 0)

            let foregroundColor = isIncomingMessage
                ? theme.colors.primary
                : theme.colors.outgoingMessageText
            let inactiveWaveformColor = foregroundColor.withAlphaComponent(0.55)
            playPauseButton.tintColor = foregroundColor
            durationLabel.textColor = foregroundColor
            waveformView.audioVisualizationView.highlightedBarColor = foregroundColor
            waveformView.audioVisualizationView.barColor = inactiveWaveformColor

            waveformView.content = .init(
                isRecording: false,
                duration: content.duration ?? 0,
                currentTime: TimeInterval(waveformView.slider.value),
                waveform: Self.displayWaveform(content.waveformData)
            )
        }

        static func displayWaveform(_ waveform: [Float]?) -> [Float] {
            guard let waveform, waveform.contains(where: { $0 > 0 }) else {
                return fallbackWaveform
            }
            return waveform
        }

        // MARK: - View updates

        open func updatePlayPauseButton(
            for state: AudioPlaybackState
        ) {
            playPauseButton.setImage(theme.icons.playFill, for: .normal)
            playPauseButton.isSelected = state == .playing
            switch state {
            case .notLoaded, .loading:
                playPauseButton.setImage(nil, for: .selected)
            case .paused, .playing, .stopped:
                playPauseButton.setImage(theme.icons.pauseFill, for: .selected)
            default:
                log.assert(false, "Unhandled `AudioPlaybackState` \(state)")
            }
        }

        open func updatePlaybackLoadingIndicator(
            for state: AudioPlaybackState
        ) {
            if state == .loading {
                playbackLoadingIndicator.isHidden = false
                playbackLoadingIndicator.startRotation()
            } else {
                playbackLoadingIndicator.isHidden = true
                playbackLoadingIndicator.stopRotating()
            }
        }

        open func updateDurationLabel(
            for state: AudioPlaybackState,
            duration: TimeInterval,
            currentTime: TimeInterval
        ) {
            durationLabel.isHidden = false
            switch state {
            case .notLoaded, .loading, .stopped:
                durationLabel.text = formatters.videoDuration.format(duration)
            case .paused, .playing:
                durationLabel.text = formatters.videoDuration.format(min(currentTime, duration))
            default:
                log.assert(false, "Unhandled `AudioPlaybackState` \(state)")
            }
        }

        open func updateWaveformView(
            for state: AudioPlaybackState,
            duration: TimeInterval,
            currentTime: TimeInterval
        ) {
            waveformView.content = .init(
                isRecording: false,
                duration: duration,
                currentTime: currentTime,
                waveform: waveformView.content.waveform
            )
        }

        open func updateFileIconImageView(
            for state: AudioPlaybackState
        ) {
            switch state {
            case .notLoaded, .loading, .stopped:
                fileIconImageView.isHidden = false
            case .paused, .playing:
                fileIconImageView.isHidden = true
            default:
                log.assert(false, "Unhandled `AudioPlaybackState` \(state)")
            }
        }

        open func updatePlaybackRateButton(
            for state: AudioPlaybackState,
            value: Float
        ) {
            switch state {
            case .notLoaded, .loading, .stopped:
                playbackRateButton.isHidden = true
                playbackRateButton.setTitle(nil, for: .normal)
            case .paused, .playing:
                guard
                    let rateValueString = formatters.audioPlaybackRateFormatter.format(value)
                else {
                    playbackRateButton.isHidden = true
                    return
                }
                playbackRateButton.isHidden = false
                playbackRateButton.setTitle(L10n.Audio.Player.rate(rateValueString), for: .normal)
            default:
                log.assert(false, "Unhandled `AudioPlaybackState` \(state)")
            }
        }
    }
}
