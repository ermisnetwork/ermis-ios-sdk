import AVFoundation
import UIKit
import AudioToolbox
import CoreMedia
import ErmisChat

public enum AudioUnitType {
    case remoteIO
    case voiceProcessingIO
}

public class ErmisPlayer: AppLifecycleObserver {

    // MARK: - Video Properties
    public var videoLayer: AVSampleBufferDisplayLayer
    public let synchronizer: AVSampleBufferRenderSynchronizer

    // MARK: - Audio Unit
    private let videoQueue = DispatchQueue(label: "ermis.player.video.queue", qos: .unspecified)

    // MARK: - State
    private var isPlaying = false
    package var isReadyToPlay: Bool = false
    private var hasSetupRenderer: Bool = false
    private var audioUnitStarted: Bool = false
    private var isRequestingMedia: Bool = false
    var isEnable: Bool = false {
        didSet {
            if isEnable {
                log.debug("[Player] START REQUEST MEDIA - IS ENABLE TRUE")
                startRequestingMediaIfNeeded()
            } else {
                log.debug("[Player] STOP REQUEST MEDIA - IS ENABLE FAILED")
                stopRequestingMedia()
            }
        }
    }

    private var isApplicationActive: Bool {
        return UIApplication.shared.applicationState == .active
    }

    // MARK: - Video Buffer
    private var videoBuffer: [(sampleBuffer: CMSampleBuffer, timestamp: CMTime)] = []
    private let videoBufferLock = NSLock()
    public var maxVideoBufferSize: Int = 5

    // MARK: - Jitter Buffer
    public var targetLatencyMs: Double = 40  // Reduced for lower latency
    private var playbackStarted: Bool = false
    private var minSamplesToStart: Int = 0

    // MARK: - Debug
    private var totalSamplesEnqueued: Int = 0
    private var totalSamplesPlayed: Int = 0
    private var renderCallbackCount: Int = 0
    private var droppedSamples: Int = 0

    // MARK: - Initialization

    public init() {
        synchronizer = AVSampleBufferRenderSynchronizer()
        videoLayer = AVSampleBufferDisplayLayer()
    }

    deinit {
        log.debug("[Player] DEINIT - Enqueued: \(totalSamplesEnqueued), Played: \(totalSamplesPlayed), Dropped: \(droppedSamples)")
        stopRequestingMedia()
        stop()
    }

    // MARK: - Setup

    package func setupPlayerIfNeeded() {
        log.debug("[Player] Setup Player")
        isReadyToPlay = true
        if !hasSetupRenderer {
            hasSetupRenderer = true

            synchronizer.addRenderer(videoLayer)
            videoLayer.videoGravity = .resizeAspectFill
            isRequestingMedia = true
            startRequestingMediaData()
        }
    }

    // MARK: - Control

    func stop() {
        synchronizer.rate = 0

        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.flush()
        }

        playbackStarted = false

        videoBufferLock.lock()
        videoBuffer.removeAll()
        videoBufferLock.unlock()

        isPlaying = false
    }

    func startRequestingMediaIfNeeded() {
        guard isEnable, !isRequestingMedia, isApplicationActive else {
            log.debug("[Player] no need requetsing media: isEnable: \(isEnable), isRequestingMedia: \(isRequestingMedia), isApplicationActive: \(isApplicationActive)")
            return
        }
        if isEnable {
            isRequestingMedia = true
            startRequestingMediaData()
        }

    }

    func startRequestingMediaData() {
        log.debug("[Player] Start requesting media")
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                self?.supplyVideoData()
            }
        } else {
            videoLayer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                self?.supplyVideoData()
            }
        }
    }

    func stopRequestingMedia() {
        log.debug("[Player] Stop requesting media")
        isPlaying = false
        synchronizer.rate = 0
        isRequestingMedia = false
        videoBufferLock.lock()
        videoBuffer.removeAll()
        videoBufferLock.unlock()
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.stopRequestingMediaData()
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.stopRequestingMediaData()
            videoLayer.flush()
        }
    }

    // MARK: - Video

    private func supplyVideoData() {
        videoBufferLock.lock()
        defer { videoBufferLock.unlock() }

        guard !videoBuffer.isEmpty else { return }

        var isReady: Bool
        if #available(iOS 17.0, *) {
            isReady = videoLayer.sampleBufferRenderer.isReadyForMoreMediaData
        } else {
            isReady = videoLayer.isReadyForMoreMediaData
        }

        while isReady, !videoBuffer.isEmpty {
            let (sampleBuffer, timestamp) = videoBuffer.removeFirst()
            if #available(iOS 17.0, *) {
                videoLayer.sampleBufferRenderer.enqueue(sampleBuffer)
                totalSamplesPlayed += 1
                isReady = videoLayer.sampleBufferRenderer.isReadyForMoreMediaData
            } else {
                videoLayer.enqueue(sampleBuffer)
                totalSamplesPlayed += 1
                isReady = videoLayer.isReadyForMoreMediaData
            }

            if !isPlaying {
                log.debug("[Player] start playing at timestamp: \(timestamp)")
                synchronizer.setRate(1, time: timestamp)
                isPlaying = true
            }
        }
    }

    package func enqueueVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        log.debug("[Player] Enqueue video sample buffer: \(timestamp)")
        guard hasSetupRenderer, isApplicationActive else {
            if !videoBuffer.isEmpty {
                videoBuffer.removeAll()
            }
            return
        }

        videoBufferLock.lock()
        defer { videoBufferLock.unlock() }
        totalSamplesEnqueued += 1
        videoBuffer.append((sampleBuffer, timestamp))
        if videoBuffer.count > maxVideoBufferSize {
            droppedSamples += videoBuffer.count - maxVideoBufferSize
            videoBuffer.removeFirst(videoBuffer.count - maxVideoBufferSize)
        }
    }

    // MARK: - Orientation & Lifecycle

    public func handleDeviceOrientationEvent(_ videoOrientation: VideoOrientation) {

    }

    public func appDidBecomeActive() {
        guard isReadyToPlay else {
            log.warning("[Player] appdidbecomeactive but not ready to play")
            return
        }
        log.debug("[Player] Application did become active")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startRequestingMediaIfNeeded()
        }
    }

    public func appWillResignActive() {}

    public func appDidEnterBackground() {
        log.debug("[Player] STOP REQUEST MEDIA - APP DID ENTER BG")
        stopRequestingMedia()
    }
}
