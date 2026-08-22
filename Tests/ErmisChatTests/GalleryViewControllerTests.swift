//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChatUI
import AVFoundation
import UIKit
import XCTest

@MainActor
final class GalleryViewControllerTests: XCTestCase {
    func testPanWithoutZoomTransitionDoesNotCrash() {
        let gallery = GalleryViewController()

        // Channel Info can use the system modal transition. Its gallery must keep
        // the close button usable instead of force-unwrapping a missing zoom controller.
        gallery.handlePan(with: UIPanGestureRecognizer())

        XCTAssertNil(gallery.transitionController)
    }

    func testCancellingVideoResolutionInvalidatesAlreadyQueuedCompletionToken() {
        let cell = VideoAttachmentGalleryCell()
        let activeToken = cell.resolutionToken

        cell.cancelPendingOriginalResolution()

        XCTAssertNotEqual(cell.resolutionToken, activeToken)
    }

    func testVideoControlsCannotBeginGalleryDismissalPan() {
        XCTAssertFalse(
            GalleryDismissalPanPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 300),
                beginsInsidePlaybackControls: true,
                hasTransitionController: true
            )
        )
    }

    func testGalleryDismissalPanRequiresAvailableTransitionAndDominantDownwardMotion() {
        XCTAssertFalse(
            GalleryDismissalPanPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 300),
                beginsInsidePlaybackControls: false,
                hasTransitionController: false
            )
        )
        XCTAssertFalse(
            GalleryDismissalPanPolicy.shouldBegin(
                velocity: CGPoint(x: 300, y: 50),
                beginsInsidePlaybackControls: false,
                hasTransitionController: true
            )
        )
        XCTAssertFalse(
            GalleryDismissalPanPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: -300),
                beginsInsidePlaybackControls: false,
                hasTransitionController: true
            )
        )
        XCTAssertTrue(
            GalleryDismissalPanPolicy.shouldBegin(
                velocity: CGPoint(x: 20, y: 300),
                beginsInsidePlaybackControls: false,
                hasTransitionController: true
            )
        )
    }
}

@MainActor
final class VideoPlaybackControlViewTests: XCTestCase {
    func testFailureTelemetryRedactsAssetAndErrorDetails() {
        let remoteAsset = AVURLAsset(url: URL(string: "https://example.invalid/private/video.mp4?token=secret")!)
        let localAsset = AVURLAsset(url: URL(fileURLWithPath: "/private/secret/video.mov"))

        XCTAssertEqual(VideoPlaybackFailureTelemetry.source(for: remoteAsset), "remote")
        XCTAssertEqual(VideoPlaybackFailureTelemetry.source(for: localAsset), "local")
        XCTAssertEqual(
            VideoPlaybackFailureTelemetry.errorDomain(
                for: NSError(domain: AVFoundationErrorDomain, code: -11_800)
            ),
            "avfoundation"
        )
        XCTAssertEqual(
            VideoPlaybackFailureTelemetry.errorDomain(
                for: NSError(domain: "private.server.error", code: 403)
            ),
            "other"
        )
        XCTAssertEqual(
            VideoPlaybackFailureTelemetry.errorCode(
                for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)
            ),
            NSURLErrorCannotDecodeContentData
        )
    }

    func testResumePolicyPreservesPlaybackIntentWhilePlayerIsWaiting() {
        XCTAssertTrue(VideoPlaybackResumePolicy.shouldResume(after: .playing))
        XCTAssertTrue(VideoPlaybackResumePolicy.shouldResume(after: .waitingToPlayAtSpecifiedRate))
        XCTAssertFalse(VideoPlaybackResumePolicy.shouldResume(after: .paused))
    }

    func testResumePolicyUsesImmediatePlayback() {
        let player = SeekRecordingPlayer()

        VideoPlaybackResumePolicy.resume(player, rate: 1)

        XCTAssertEqual(player.immediatePlayCount, 1)
    }

    func testPlaybackResumesWithoutWaitingForSeekCompletion() {
        let duration = CMTime(seconds: 120, preferredTimescale: 600)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(.init(start: .zero, duration: duration))
        let player = SeekRecordingPlayer(playerItem: AVPlayerItem(asset: composition))
        player.completesSeek = false
        let control = VideoPlaybackControlView()
        control.player = player
        control.content = .init(
            videoDuration: duration.seconds,
            videoState: .paused,
            playingProgress: 0.25
        )
        control.shouldResumeAfterScrubbing = true
        control.timeSlider.value = 0.85

        control.timeSliderDidEndEditing(control.timeSlider)

        XCTAssertEqual(player.tolerantSeekCount, 1)
        XCTAssertEqual(player.immediatePlayCount, 1)
    }

    func testSliderTargetsAreRegisteredWhenControlEntersViewHierarchy() {
        let host = UIView()
        let control = VideoPlaybackControlView()

        host.addSubview(control)

        XCTAssertTrue(control.timeSlider.allTargets.contains(control))
        XCTAssertEqual(
            control.timeSlider.actions(forTarget: control, forControlEvent: .touchDown),
            [NSStringFromSelector(#selector(control.timeSliderDidBeginEditing))]
        )
        XCTAssertEqual(
            control.timeSlider.actions(forTarget: control, forControlEvent: .valueChanged),
            [NSStringFromSelector(#selector(control.timeSliderDidChange))]
        )
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            XCTAssertEqual(
                control.timeSlider.actions(forTarget: control, forControlEvent: event),
                [NSStringFromSelector(#selector(control.timeSliderDidEndEditing))]
            )
        }
    }

    func testScrubbingPreviewsTimeAndCommitsOnlyOneSeekWhenEditingEnds() {
        let duration = CMTime(seconds: 120, preferredTimescale: 600)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(.init(start: .zero, duration: duration))
        let player = SeekRecordingPlayer(playerItem: AVPlayerItem(asset: composition))
        let control = VideoPlaybackControlView()
        control.player = player
        control.content = .init(
            videoDuration: duration.seconds,
            videoState: .paused,
            playingProgress: 0.25
        )

        control.timeSliderDidBeginEditing(control.timeSlider)
        for value: Float in [0.4, 0.6, 0.75] {
            control.timeSlider.value = value
            control.timeSliderDidChange(control.timeSlider, event: UIEvent())
        }

        XCTAssertEqual(player.tolerantSeekCount, 0)
        XCTAssertEqual(control.timeSlider.value, 0.75, accuracy: 0.001)
        XCTAssertEqual(
            control.timestampLabel.text,
            control.videoDurationFormatter.format(90)
        )

        // A player-state update during the drag must not move the thumb back to 25%.
        control.content.videoState = .loading
        XCTAssertEqual(control.timeSlider.value, 0.75, accuracy: 0.001)

        control.timeSliderDidEndEditing(control.timeSlider)

        XCTAssertEqual(player.tolerantSeekCount, 1)
        XCTAssertEqual(player.lastTarget?.seconds ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(player.lastToleranceBefore, .zero)
        XCTAssertEqual(player.lastToleranceAfter?.seconds ?? -1, 2, accuracy: 0.001)
    }

    func testSeekPlanClassifiesTailAndAvoidsExactEndOfResource() {
        let plan = VideoPlaybackSeekPlan.make(sliderValue: 1, duration: 120)

        XCTAssertEqual(plan?.region, .tail)
        XCTAssertEqual(plan?.target.seconds ?? -1, 119.5, accuracy: 0.001)
        XCTAssertEqual(plan?.targetPercentBucket, 100)
        XCTAssertEqual(plan?.toleranceBefore, .zero)
        XCTAssertEqual(plan?.toleranceAfter.seconds ?? -1, 2, accuracy: 0.001)
    }

    func testSeekPlanCannotAcceptCurrentNinetyPercentForBackwardEightyFivePercentSeek() {
        let duration: TimeInterval = 564
        let plan = VideoPlaybackSeekPlan.make(
            sliderValue: 0.85,
            duration: duration,
            currentTime: duration * 0.90
        )

        XCTAssertEqual(plan?.targetPercentBucket, 85)
        XCTAssertEqual(plan?.toleranceBefore.seconds ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(plan?.toleranceAfter, .zero)
        XCTAssertFalse(plan?.contains(CMTime(seconds: duration * 0.90, preferredTimescale: 600)) == true)
        XCTAssertTrue(plan?.contains(CMTime(seconds: duration * 0.85, preferredTimescale: 600)) == true)
    }

    func testSeekPlanUsesOppositeDirectionalWindowForForwardSeek() {
        let duration: TimeInterval = 564
        let plan = VideoPlaybackSeekPlan.make(
            sliderValue: 0.90,
            duration: duration,
            currentTime: duration * 0.70
        )

        XCTAssertEqual(plan?.targetPercentBucket, 90)
        XCTAssertEqual(plan?.toleranceBefore, .zero)
        XCTAssertEqual(plan?.toleranceAfter.seconds ?? -1, 2, accuracy: 0.001)
        XCTAssertFalse(plan?.contains(CMTime(seconds: duration * 0.70, preferredTimescale: 600)) == true)
        XCTAssertTrue(plan?.contains(CMTime(seconds: duration * 0.90, preferredTimescale: 600)) == true)
    }

    func testProgressProbeRequiresActualPlayheadAdvance() {
        XCTAssertFalse(
            VideoPlaybackProgressProbe.didAdvance(
                from: CMTime(seconds: 100, preferredTimescale: 600),
                to: CMTime(seconds: 100.1, preferredTimescale: 600)
            )
        )
        XCTAssertTrue(
            VideoPlaybackProgressProbe.didAdvance(
                from: CMTime(seconds: 100, preferredTimescale: 600),
                to: CMTime(seconds: 100.25, preferredTimescale: 600)
            )
        )
    }

    func testDebouncedSeekCommitsWhenTouchUpActionIsMissing() async {
        let duration = CMTime(seconds: 120, preferredTimescale: 600)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(.init(start: .zero, duration: duration))
        let player = SeekRecordingPlayer(playerItem: AVPlayerItem(asset: composition))
        let control = VideoPlaybackControlView()
        control.scrubSeekDebounceInterval = 0.01
        control.player = player
        control.content = .init(
            videoDuration: duration.seconds,
            videoState: .paused,
            playingProgress: 0.25
        )
        let committed = expectation(description: "debounced seek committed")
        player.onTolerantSeek = { committed.fulfill() }

        control.timeSliderDidBeginEditing(control.timeSlider)
        for value: Float in [0.4, 0.6, 0.75] {
            control.timeSlider.value = value
            control.timeSliderDidChange(control.timeSlider, event: UIEvent())
        }

        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(player.tolerantSeekCount, 1)
        XCTAssertEqual(player.lastTarget?.seconds ?? -1, 90, accuracy: 0.001)
    }
}

private final class SeekRecordingPlayer: AVPlayer {
    private(set) var tolerantSeekCount = 0
    private(set) var lastTarget: CMTime?
    private(set) var lastToleranceBefore: CMTime?
    private(set) var lastToleranceAfter: CMTime?
    private(set) var immediatePlayCount = 0
    var onTolerantSeek: (() -> Void)?
    var completesSeek = true

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        tolerantSeekCount += 1
        lastTarget = time
        lastToleranceBefore = toleranceBefore
        lastToleranceAfter = toleranceAfter
        onTolerantSeek?()
        if completesSeek {
            completionHandler(true)
        }
    }

    override func playImmediately(atRate rate: Float) {
        immediatePlayCount += 1
    }
}
