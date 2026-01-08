import AVFoundation
import UIKit
import CoreMedia
import ErmisChat

public class ErmisPlayer: AppLifecycleObserver {

    // MARK: - Video Properties
    public private(set) var videoLayer: AVSampleBufferDisplayLayer

    // MARK: - Queue
    private let videoQueue = DispatchQueue(label: "ermis.player.video.queue", qos: .userInteractive)

    // MARK: - State
    private var isPlaying = false
    package var isReadyToPlay: Bool = false
    private var hasSetupRenderer: Bool = false

    var onRequiredKeyframe: (() -> Void)?

    var isEnable: Bool = false {
        didSet {
            if isEnable {
                log.debug("[Player] Enabling player")
                start()
            } else {
                log.debug("[Player] Disabling player")
                stop()
            }
        }
    }

    private var isApplicationActive: Bool {
        return UIApplication.shared.applicationState == .active
    }

    // MARK: - Initialization

    public init() {
        videoLayer = AVSampleBufferDisplayLayer()
        configureLayer()
        setupNotifications()
    }

    func stopRequestingMedia() {

    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    private func configureLayer() {
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.backgroundColor = UIColor.black.cgColor

        // CRITICAL: Set controlTimebase to nil for immediate display mode
        // This tells the layer to display frames immediately as they arrive
        // instead of waiting for presentation timestamps
        videoLayer.controlTimebase = nil

        // Prevent capture for privacy
        videoLayer.preventsCapture = false
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlerDecodeFailed),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: videoLayer
        )
    }

    // MARK: - Setup

    package func setupPlayerIfNeeded() {
        log.debug("[Player] Setup Player")
        isReadyToPlay = true

        if !hasSetupRenderer {
            hasSetupRenderer = true
            if isEnable && isApplicationActive {
                start()
            }
        }
    }

    // MARK: - Control

    private func start() {
        guard isReadyToPlay, isApplicationActive, !isPlaying else {
            log.debug("[Player] Cannot start: ready=\(isReadyToPlay), active=\(isApplicationActive), playing=\(isPlaying)")
            return
        }

        isPlaying = true
        onRequiredKeyframe?()
        log.debug("[Player] Started")
    }

    func stop() {
        isPlaying = false

        videoQueue.async { [weak self] in
            guard let self = self else { return }

            if #available(iOS 17.0, *) {
                self.videoLayer.sampleBufferRenderer.flush()
            } else {
                self.videoLayer.flush()
            }
        }

        log.debug("[Player] Stopped")
    }

    // MARK: - Video Frame Handling

    /// Enqueue a video sample buffer for immediate display
    /// - Parameters:
    ///   - sampleBuffer: The decoded video frame
    ///   - timestamp: The presentation timestamp (used for logging only in immediate mode)
    package func enqueueVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        guard isPlaying, isApplicationActive else {
            log.debug("[Player] Not playing because is not playing, or app is not active")
            return
        }

        videoQueue.async { [weak self] in
            self?.enqueueFrame(sampleBuffer)
        }
    }

    private func enqueueFrame(_ sampleBuffer: CMSampleBuffer) {
        // Check if layer needs recovery
        if needsKeyframe() {
            log.warning("[Player] Layer needs keyframe")
            flushAndRequestKeyframe()
            return
        }

        // Mark for immediate display
        markForImmediateDisplay(sampleBuffer)

        // Check if ready and enqueue
        var isReady: Bool
        if #available(iOS 17.0, *) {
            isReady = videoLayer.sampleBufferRenderer.isReadyForMoreMediaData
        } else {
            isReady = videoLayer.isReadyForMoreMediaData
        }

        guard isReady else {
            log.debug("[Player] Layer not ready, dropping frame")
            return
        }

        // Enqueue the frame
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            videoLayer.enqueue(sampleBuffer)
        }
    }

    /// Mark sample buffer for immediate display - critical for real-time video
    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
              let attachment = attachments.first else {
            return
        }

        // Display immediately without waiting for presentation timestamp
        attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
    }

    private func flushAndRequestKeyframe() {
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.flush()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onRequiredKeyframe?()
        }
    }

    private func needsKeyframe() -> Bool {
        if #available(iOS 14.0, *) {
            if videoLayer.requiresFlushToResumeDecoding {
                return true
            }
        }
        return videoLayer.status == .failed
    }

    @objc private func handlerDecodeFailed(_ notification: Notification) {
        if let error = notification.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError {
            log.error("[Player] Decode failed: \(error.localizedDescription)")
        }

        videoQueue.async { [weak self] in
            self?.flushAndRequestKeyframe()
        }
    }

    // MARK: - Lifecycle

    public func handleDeviceOrientationEvent(_ videoOrientation: VideoOrientation) {}

    public func appDidBecomeActive() {
        guard isReadyToPlay else {
            log.warning("[Player] appDidBecomeActive but not ready")
            return
        }

        log.debug("[Player] App became active")

        if isEnable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.onRequiredKeyframe?()
                self?.start()
            }
        }
    }

    public func appWillResignActive() {}

    public func appDidEnterBackground() {
        log.debug("[Player] App entered background")
        stop()
    }
}


// MARK: - Alternative: Minimal Jitter Buffer for Network Variance

/// Use this if you experience frame reordering from the network
/// but still want low latency
final class JitterBuffer {

    private var frames: [(buffer: CMSampleBuffer, order: UInt64)] = []
    private var insertCounter: UInt64 = 0
    private let lock = NSLock()

    // Very small buffer for minimal latency
    private let targetDepth: Int = 2
    private let maxDepth: Int = 5

    func push(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        frames.append((sampleBuffer, insertCounter))
        insertCounter += 1

        // Keep buffer small
        while frames.count > maxDepth {
            frames.removeFirst()
        }
    }

    func pull() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }

        // Wait for minimum frames
        guard frames.count >= targetDepth else { return nil }

        return frames.removeFirst().buffer
    }

    func flush() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }
}
