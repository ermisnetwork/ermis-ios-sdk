//
// Copyright 2025 Ermis Inc.
//

import AVKit
import ErmisChat
import UIKit

enum VideoPlaybackSeekRegion: String, Equatable {
    case head
    case middle
    case tail

    static func make(normalizedProgress: Double) -> Self {
        if normalizedProgress < 0.2 {
            return .head
        }
        if normalizedProgress >= 0.8 {
            return .tail
        }
        return .middle
    }
}

struct VideoPlaybackSeekPlan: Equatable {
    let target: CMTime
    let toleranceBefore: CMTime
    let toleranceAfter: CMTime
    let region: VideoPlaybackSeekRegion
    let targetPercentBucket: Int

    static func make(
        sliderValue: Float,
        duration: TimeInterval,
        currentTime: TimeInterval = 0
    ) -> Self? {
        guard duration.isFinite, duration > 0 else { return nil }
        let normalized = min(1, max(0, Double(sliderValue)))
        let endInset = min(0.5, duration / 2)
        let targetSeconds = min(duration * normalized, duration - endInset)
        let safeCurrentTime = currentTime.isFinite ? max(0, currentTime) : 0
        let directionalTolerance = CMTime(
            seconds: min(2, duration / 20),
            preferredTimescale: 600
        )
        let isBackwardSeek = targetSeconds < safeCurrentTime
        return .init(
            target: CMTime(seconds: targetSeconds, preferredTimescale: 600),
            toleranceBefore: isBackwardSeek ? directionalTolerance : .zero,
            toleranceAfter: isBackwardSeek ? .zero : directionalTolerance,
            region: .make(normalizedProgress: normalized),
            targetPercentBucket: Int((normalized * 20).rounded()) * 5
        )
    }

    func contains(_ time: CMTime) -> Bool {
        guard time.isNumeric,
              target.isNumeric,
              toleranceBefore.isNumeric,
              toleranceAfter.isNumeric else { return false }
        let epsilon = 0.25
        let lowerBound = target.seconds - toleranceBefore.seconds - epsilon
        let upperBound = target.seconds + toleranceAfter.seconds + epsilon
        return time.seconds >= lowerBound && time.seconds <= upperBound
    }
}

enum VideoPlaybackProgressProbe {
    static func didAdvance(from start: CMTime, to end: CMTime) -> Bool {
        guard start.isNumeric, end.isNumeric else { return false }
        return end.seconds - start.seconds >= 0.2
    }
}

enum VideoPlaybackResumePolicy {
    static func shouldResume(after status: AVPlayer.TimeControlStatus) -> Bool {
        switch status {
        case .playing, .waitingToPlayAtSpecifiedRate:
            return true
        case .paused:
            return false
        @unknown default:
            return false
        }
    }

    static func resume(_ player: AVPlayer, rate: Float) {
        player.playImmediately(atRate: rate)
    }
}

/// A view that shows playback controls and timeline for the given player.
open class VideoPlaybackControlView: _View, UIProvider {
    /// The type describing the content of the view.
    public struct Content {
        /// The type describing the current video state.
        public enum VideoState {
            case playing
            case paused
            case loading
        }

        /// A video duration in seconds.
        public var videoDuration: TimeInterval
        /// A video playback state.
        public var videoState: VideoState
        /// A video playback progress in [0...1] range
        public var playingProgress: Double

        /// A current location in video.
        public var currentTime: TimeInterval {
            playingProgress * videoDuration
        }

        public init(
            videoDuration: TimeInterval,
            videoState: VideoState,
            playingProgress: Double
        ) {
            self.videoDuration = videoDuration
            self.videoState = videoState
            self.playingProgress = playingProgress
        }

        public static var initial: Self {
            .init(
                videoDuration: 0,
                videoState: .loading,
                playingProgress: 0
            )
        }
    }

    private var playerTimeChangesObserver: Any?
    private var playerStatusObserver: NSKeyValueObservation?
    private var playerItemObserver: NSKeyValueObservation?
    private var itemDurationObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var isScrubbing = false
    var shouldResumeAfterScrubbing = false
    private var scrubResumeRate: Float = 1
    private var seekGeneration = 0
    private var pendingScrubSeekWorkItem: DispatchWorkItem?
    private var pendingSeekProgressProbe: DispatchWorkItem?
    var scrubSeekDebounceInterval: TimeInterval = 0.3

    /// A content displayed by the view.
    open var content: Content = .initial {
        didSet { updateContentIfNeeded() }
    }

    /// A player the view listens to.
    open weak var player: AVPlayer? {
        didSet {
            guard oldValue != player else { return }

            cancelPendingScrubSeek()
            cancelSeekProgressProbe()
            unsubscribeFromPlayerNotifications(oldValue)
            content = .initial
            subscribeToPlayerNotifications()

            player?.seek(to: .zero)
            player?.play()
        }
    }

    /// A loading indicator that is visible when video is loading.
    open private(set) lazy var loadingIndicator: LoadingIndicator = components
        .loadingIndicator.init()
        .withoutAutoresizingMaskConstraints

    /// A playback control button.
    open private(set) lazy var playPauseButton: UIButton = UIButton()
        .withoutAutoresizingMaskConstraints

    /// A label displaying the current time position.
    open private(set) lazy var timestampLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport

    /// A label displaying the overall video duration.
    open private(set) lazy var durationLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport

    /// A slider used to show a timeline.
    open private(set) lazy var timeSlider: UISlider = UISlider()
        .withoutAutoresizingMaskConstraints

    /// A container for playback button and time labels.
    open private(set) lazy var rootContainer: ContainerStackView = ContainerStackView(axis: .vertical)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "rootContainer")

    /// A formatter to convert video duration to textual representation.
    open lazy var videoDurationFormatter: VideoDurationFormatter = formatters.videoDuration

    override open func setUp() {
        super.setUp()

        timeSlider.minimumValue = 0
        timeSlider.maximumValue = 1
        timeSlider.addTarget(self, action: #selector(timeSliderDidBeginEditing), for: .touchDown)
        timeSlider.addTarget(self, action: #selector(timeSliderDidChange), for: .valueChanged)
        timeSlider.addTarget(self, action: #selector(timeSliderDidEndEditing), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        log.info("[VIDEO_SCRUB] state=controls_registered", subsystems: .mls)

        timestampLabel.font = theme.fonts.footnote.bold
        durationLabel.font = theme.fonts.footnote.bold

        playPauseButton.addTarget(self, action: #selector(handleTapOnPlayPauseButton), for: .touchUpInside)
    }

    override open func setUpUI() {
        super.setUpUI()

        let bottomContainer = UIView().withoutAutoresizingMaskConstraints

        bottomContainer.addSubview(timestampLabel)
        timestampLabel.pin(anchors: [.leading, .top], to: bottomContainer)

        bottomContainer.addSubview(playPauseButton)
        playPauseButton.pin(anchors: [.centerX, .top, .bottom], to: bottomContainer)

        bottomContainer.addSubview(durationLabel)
        durationLabel.pin(anchors: [.trailing, .top], to: bottomContainer)

        addSubview(rootContainer)
        rootContainer.pin(to: self)
        rootContainer.addArrangedSubview(timeSlider, respectsLayoutMargins: true)
        rootContainer.addArrangedSubview(bottomContainer, respectsLayoutMargins: true)

        addSubview(loadingIndicator)
        loadingIndicator.pin(anchors: [.centerX, .centerY], to: playPauseButton)
    }

    override open func setUpTheme() {
        super.setUpTheme()

        playPauseButton.setTitleColor(.black, for: .normal)
        timestampLabel.text = videoDurationFormatter.format(0)
        durationLabel.text = videoDurationFormatter.format(0)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        // Do not let player/KVO updates move the thumb back underneath the user's finger.
        // While scrubbing, `timeSliderDidChange` owns the preview value and label.
        if !isScrubbing {
            timeSlider.value = .init(content.playingProgress)
            timestampLabel.text = videoDurationFormatter.format(content.currentTime)
        }
        durationLabel.text = videoDurationFormatter.format(content.videoDuration)

        switch content.videoState {
        case .playing:
            playPauseButton.isHidden = false
            playPauseButton.setImage(theme.icons.pause, for: .normal)
        case .paused:
            playPauseButton.isHidden = false
            playPauseButton.setImage(theme.icons.play, for: .normal)
        case .loading:
            playPauseButton.isHidden = true
        }

        let showLoader = playPauseButton.isHidden
        if loadingIndicator.isVisible != showLoader {
            loadingIndicator.isVisible = showLoader
        }
    }

    @objc open func timeSliderDidBeginEditing(_ sender: UISlider) {
        cancelPendingScrubSeek()
        isScrubbing = true
        shouldResumeAfterScrubbing = player.map {
            VideoPlaybackResumePolicy.shouldResume(after: $0.timeControlStatus)
        } ?? false
        if let rate = player?.rate, rate > 0 {
            scrubResumeRate = rate
        }
        seekGeneration &+= 1
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        log.info("[VIDEO_SCRUB] state=began", subsystems: .mls)
    }

    /// Is invoked when time slider changes the value.
    @objc open func timeSliderDidChange(_ sender: UISlider, event: UIEvent) {
        let previewTime = content.videoDuration * Double(sender.value)
        guard previewTime.isFinite, previewTime >= 0 else { return }
        timestampLabel.text = videoDurationFormatter.format(previewTime)
        scheduleScrubSeekFallback(for: sender)
    }

    @objc open func timeSliderDidEndEditing(_ sender: UISlider) {
        cancelPendingScrubSeek()
        isScrubbing = false
        log.info("[VIDEO_SCRUB] state=ended", subsystems: .mls)
        seek(to: sender.value, resumeWhenFinished: shouldResumeAfterScrubbing)
    }

    /// Some gallery/gesture combinations do not deliver the slider's touch-up action even though
    /// `isTracking` becomes false. Coalesce value changes and commit once after tracking ends so a
    /// missing touch-up cannot leave the player permanently paused.
    private func scheduleScrubSeekFallback(for sender: UISlider) {
        cancelPendingScrubSeek()
        let workItem = DispatchWorkItem { [weak self, weak sender] in
            guard let self, let sender, self.isScrubbing else { return }
            if sender.isTracking {
                self.scheduleScrubSeekFallback(for: sender)
                return
            }
            self.pendingScrubSeekWorkItem = nil
            self.isScrubbing = false
            log.info("[VIDEO_SCRUB] state=debounced_commit", subsystems: .mls)
            self.seek(
                to: sender.value,
                resumeWhenFinished: self.shouldResumeAfterScrubbing
            )
        }
        pendingScrubSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + scrubSeekDebounceInterval,
            execute: workItem
        )
    }

    private func cancelPendingScrubSeek() {
        pendingScrubSeekWorkItem?.cancel()
        pendingScrubSeekWorkItem = nil
    }

    private func cancelSeekProgressProbe() {
        pendingSeekProgressProbe?.cancel()
        pendingSeekProgressProbe = nil
    }

    /// Commits one direction-bounded, keyframe-tolerant seek when scrubbing ends. Seeking on every slider
    /// `valueChanged` event creates overlapping AVFoundation range demands and cancellation churn
    /// for remote encrypted media. An unbounded tolerance on both sides can accept the current
    /// position for a nearby backward seek; a two-second directional window preserves efficient
    /// keyframe selection without allowing a 90% position to satisfy an 85% target.
    private func seek(to sliderValue: Float, resumeWhenFinished: Bool) {
        guard let player,
              let item = player.currentItem,
              let plan = VideoPlaybackSeekPlan.make(
                sliderValue: sliderValue,
                duration: content.videoDuration,
                currentTime: player.currentTime().seconds
              ) else { return }

        seekGeneration &+= 1
        let generation = seekGeneration
        cancelSeekProgressProbe()
        item.cancelPendingSeeks()

        let startedAt = ProcessInfo.processInfo.systemUptime
        log.info(
            "[VIDEO_SEEK] state=started region=\(plan.region.rawValue) "
                + "target_bucket=\(plan.targetPercentBucket)",
            subsystems: .mls
        )
        player.seek(
            to: plan.target,
            toleranceBefore: plan.toleranceBefore,
            toleranceAfter: plan.toleranceAfter
        ) { [weak player] finished in
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
            let milliseconds = min(Double(Int.max), (elapsed * 1_000).rounded())
            let landed = player.map { plan.contains($0.currentTime()) } ?? false
            log.info(
                "[VIDEO_SEEK] state=completed region=\(plan.region.rawValue) "
                    + "target_bucket=\(plan.targetPercentBucket) "
                    + "finished=\(finished ? 1 : 0) landed=\(landed ? 1 : 0) "
                    + "latency_ms=\(Int(milliseconds))",
                subsystems: .mls
            )
        }
        if resumeWhenFinished {
            log.info(
                "[VIDEO_PLAYER] state=resume_after_seek mode=immediate",
                subsystems: .mls
            )
            VideoPlaybackResumePolicy.resume(player, rate: scrubResumeRate)
        }
        scheduleSeekProgressProbe(
            player: player,
            item: item,
            plan: plan,
            generation: generation
        )
    }

    private func scheduleSeekProgressProbe(
        player: AVPlayer,
        item: AVPlayerItem,
        plan: VideoPlaybackSeekPlan,
        generation: Int
    ) {
        let baselineProbe = DispatchWorkItem { [weak self, weak player, weak item] in
            guard let self,
                  let player,
                  let item,
                  self.seekGeneration == generation,
                  !self.isScrubbing else { return }
            let baseline = player.currentTime()
            let progressProbe = DispatchWorkItem { [weak self, weak player, weak item] in
                guard let self,
                      let player,
                      let item,
                      self.seekGeneration == generation,
                      !self.isScrubbing else { return }
                self.pendingSeekProgressProbe = nil
                let advanced = VideoPlaybackProgressProbe.didAdvance(
                    from: baseline,
                    to: player.currentTime()
                )
                let landed = plan.contains(player.currentTime())
                let controlState: String
                switch player.timeControlStatus {
                case .playing:
                    controlState = "playing"
                case .waitingToPlayAtSpecifiedRate:
                    controlState = "waiting"
                case .paused:
                    controlState = "paused"
                @unknown default:
                    controlState = "unknown"
                }
                log.info(
                    "[VIDEO_SEEK] state=progress_probe region=\(plan.region.rawValue) "
                        + "target_bucket=\(plan.targetPercentBucket) "
                        + "landed=\(landed ? 1 : 0) advanced=\(advanced ? 1 : 0) "
                        + "buffer_empty=\(item.isPlaybackBufferEmpty ? 1 : 0) "
                        + "likely_to_keep_up=\(item.isPlaybackLikelyToKeepUp ? 1 : 0) "
                        + "control=\(controlState)",
                    subsystems: .mls
                )
            }
            self.pendingSeekProgressProbe = progressProbe
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: progressProbe)
        }
        pendingSeekProgressProbe = baselineProbe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: baselineProbe)
    }

    /// Is invoked when current track reached the end.
    @objc open func handleItemDidPlayToEndTime(_ notification: NSNotification) {
        player?.seek(to: .zero)
    }

    /// Is invoked when playback button is touched up inide.
    @objc open func handleTapOnPlayPauseButton() {
        switch player?.timeControlStatus {
        case .paused:
            player?.play()
        case .playing:
            player?.pause()
        default:
            break
        }
    }

    /// Unsubscribes from all notifications.
    /// Is invoked with old player when new player is set or when current view is deallocated.
    open func unsubscribeFromPlayerNotifications(_ player: AVPlayer?) {
        playerTimeChangesObserver.map { player?.removeTimeObserver($0) }
        playerTimeChangesObserver = nil

        playerStatusObserver?.invalidate()
        playerStatusObserver = nil

        playerItemObserver?.invalidate()
        playerItemObserver = nil

        itemDurationObserver?.invalidate()
        itemDurationObserver = nil

        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
    }

    /// Unsubscribes to current player notifications.
    /// Is invoked when new player is set.
    open func subscribeToPlayerNotifications() {
        guard let player = player else { return }

        let interval = CMTime(seconds: 0.05, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        playerTimeChangesObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self,
                  !self.isScrubbing,
                  let currentItem = self.player?.currentItem else { return }

            if time.isNumeric && currentItem.duration.isNumeric {
                self.content.playingProgress = time.seconds / currentItem.duration.seconds
            } else {
                self.content.playingProgress = 0
            }
        }

        playerStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            guard let self = self else { return }

            let progress: Double
            if let item = player.currentItem,
               item.duration.isNumeric,
               item.duration.seconds > 0,
               player.currentTime().isNumeric {
                progress = min(1, max(0, player.currentTime().seconds / item.duration.seconds))
            } else {
                progress = 0
            }
            let region = VideoPlaybackSeekRegion.make(normalizedProgress: progress)

            switch player.timeControlStatus {
            case .playing:
                self.content.videoState = .playing
                log.info(
                    "[VIDEO_PLAYER] state=playing region=\(region.rawValue)",
                    subsystems: .mls
                )
            case .paused:
                self.content.videoState = .paused
                log.info(
                    "[VIDEO_PLAYER] state=paused region=\(region.rawValue)",
                    subsystems: .mls
                )
            default:
                self.content.videoState = .loading
                let reason: String
                switch player.reasonForWaitingToPlay {
                case .evaluatingBufferingRate:
                    reason = "evaluating_buffering"
                case .toMinimizeStalls:
                    reason = "minimize_stalls"
                case .noItemToPlay:
                    reason = "no_item"
                default:
                    reason = "unknown"
                }
                log.info(
                    "[VIDEO_PLAYER] state=waiting region=\(region.rawValue) reason=\(reason)",
                    subsystems: .mls
                )
            }
        }

        playerItemObserver = player.observe(\.currentItem, options: [.new, .initial]) { [weak self] player, _ in
            guard let self = self else { return }

            self.content.videoDuration = 0
            self.itemDurationObserver = player.currentItem?.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
                self?.content.videoDuration = item.duration.isNumeric ? item.duration.seconds : 0
            }
            self.itemStatusObserver = player.currentItem?.observe(\.status, options: [.new, .initial]) { item, _ in
                let state: String
                switch item.status {
                case .readyToPlay:
                    state = "ready"
                case .failed:
                    state = "failed"
                default:
                    state = "unknown"
                }
                log.info("[VIDEO_PLAYER] item_state=\(state)", subsystems: .mls)
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleItemDidPlayToEndTime),
                name: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )
        }
    }

    // This is a workaround to overcome the Swift 6 warning
    private var _currentPlayer: AVPlayer? { player }

    deinit {
        cancelPendingScrubSeek()
        cancelSeekProgressProbe()
        NotificationCenter.default.removeObserver(self)
        unsubscribeFromPlayerNotifications(_currentPlayer)
    }
}
