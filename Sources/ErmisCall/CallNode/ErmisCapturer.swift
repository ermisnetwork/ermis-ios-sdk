//
// Copyright 2025 Ermis Inc.
//

import UIKit
import AVFoundation
import Combine
import ErmisChat

public class ErmisCapturer: NSObject, AppLifecycleObserver {
    public let videoCaptureSession = AVCaptureSession()

    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?

    private let sessionQueue = DispatchQueue(label: "network.ermis.session")
    private let videoQueue = DispatchQueue(label: "network.ermis.video")


    private var preset: AVCaptureSession.Preset = .iFrame960x540

    var lastDeviceOrientation: UIDeviceOrientation = .portrait
    var currentDeviceOrientation: UIDeviceOrientation = .portrait

    private let desiredFPS: Float64 = 30

    public var videoBufferPublisher = PassthroughSubject<(CMSampleBuffer, Bool), Never>()
    public var orientationPublisher = CurrentValueSubject<UIDeviceOrientation, Never>(.portrait)

    private var isReadyToStart: Bool = false
    private var isVideoSessionRunning: Bool = false
    private let videoSessionLock = NSLock()

    public override init() {
        super.init()
        setup()
        startObserverDeviceOrientation()
        startObserverNotifications()
    }

    deinit {
        log.debug("TTTT CAPTURER CLIENT DEINIT")
        self.stopCapturer()
    }

    func setup() {
        self.videoSessionLock.lock()
        videoCaptureSession.beginConfiguration()
        defer {
            videoCaptureSession.commitConfiguration()
            self.videoSessionLock.unlock()
        }

        self.videoCaptureSession.sessionPreset = self.preset
        // Setup video output
        self.videoOutput = AVCaptureVideoDataOutput()
        self.videoOutput?.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        self.videoOutput?.setSampleBufferDelegate(self, queue: self.videoQueue)

        if let videoOutput = self.videoOutput, self.videoCaptureSession.canAddOutput(videoOutput) {
            self.videoCaptureSession.addOutput(videoOutput)
            log.debug("[Capturer] Video output added to session")
        } else {
            log.error("[Capturer] Video output not added to session")
        }
    }

    func startCapturer(_ isVideoEnable: Bool) {
        isReadyToStart = true

        sessionQueue.async {
            self.isVideoSessionRunning = isVideoEnable
            if isVideoEnable {
                log.debug("[Capturer] Start video capture")
                self.videoCaptureSession.startRunning()
            }
        }
    }

    func stopCapturer() {
        isVideoSessionRunning = false
        log.debug("[Capturer] Stop video capture")
        self.videoCaptureSession.stopRunning()
    }

    public func addVideoInput(_ device: AVCaptureDevice) throws {
        if let videoInput {
            if videoInput.device != device {
                videoCaptureSession.removeInput(videoInput)
            } else {
                sessionQueue.async {
                    self.ensureVideoSessionRunning()
                }
                return
            }
        }

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard videoCaptureSession.canAddInput(videoInput) else {
            throw ClientError.CannotAddVideoInput()
        }

        sessionQueue.async {
            self.videoSessionLock.lock()
            self.videoCaptureSession.beginConfiguration()

            do {
                try device.lockForConfiguration()

                if let format = device.formats.first(where: { format in
                    let ranges = format.videoSupportedFrameRateRanges
                    return ranges.contains { $0.minFrameRate <= self.desiredFPS && self.desiredFPS <= $0.maxFrameRate }
                }) {
                    device.activeFormat = format
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(self.desiredFPS))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(self.desiredFPS))
                }

                //         guard let format = device.formats.sorted { (f1, f2) -> Bool in
                //            let width1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
                //            let width2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
                //            return width1 < width2
                //        }.last(where: { format in
                //            // use 1280 as max width demension.
                //            CMVideoFormatDescriptionGetDimensions(format.formatDescription).width <= 1280 &&
                //            (format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= desiredFPS && desiredFPS <= $0.maxFrameRate }))
                //        }) else {
                //            throw ClientError.CannotAddVideoInput()
                //        }

                device.unlockForConfiguration()
            } catch {
                log.error("[Capturer] Failed to lock device for configuration: \(error)")
                self.videoSessionLock.unlock()
            }
            self.videoCaptureSession.addInput(videoInput)
            self.videoInput = videoInput
            log.debug("[Capturer] Add video input")
            self.videoCaptureSession.commitConfiguration()
            self.videoSessionLock.unlock()
            // Start if needed.
            self.ensureVideoSessionRunning()
        }
    }

    private func ensureVideoSessionRunning() {
        if self.isReadyToStart, !self.isVideoSessionRunning {
            self.isVideoSessionRunning = true
            log.debug("[Capturer] Start video capture")
            self.videoSessionLock.lock()
            self.videoCaptureSession.startRunning()
            self.videoSessionLock.unlock()
        }
    }

    public func removeVideoInput() {
        guard let videoInput, isVideoSessionRunning else {
            return
        }
        videoCaptureSession.removeInput(videoInput)
        self.videoInput = nil
        self.isVideoSessionRunning = false
        sessionQueue.async {
            self.videoSessionLock.lock()
            log.debug("[Capturer] Remove video input")
            self.videoCaptureSession.stopRunning()
            self.videoSessionLock.unlock()
        }
    }

    func videoCapturerDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: position) else {
            return nil
        }
        return videoDevice
    }

    func startObserverNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: .AVCaptureSessionWasInterrupted,
            object: self.videoCaptureSession
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: self.videoCaptureSession
        )
    }

    public func appWillResignActive() {
//        isVideoSessionRunning = false
//
//        sessionQueue.async {
//            self.videoSessionLock.lock()
//            log.debug("[Capturer] Remove video input")
//            self.videoCaptureSession.stopRunning()
//            self.videoSessionLock.unlock()
//        }
    }

    public func appDidBecomeActive() {
        sessionQueue.async {
            self.ensureVideoSessionRunning()
        }
    }

    public func appDidEnterBackground() {
        sessionQueue.async {
            self.isVideoSessionRunning = false
        }
    }

    @objc func sessionWasInterrupted(notification: Notification) {
        sessionQueue.async {
            self.isVideoSessionRunning = false
        }
        guard let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
              let reasonIntegerValue = userInfoValue.integerValue,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) else {
            return
        }

        print("Capture session interrupted: \(reason)")

        switch reason {
        case .videoDeviceNotAvailableInBackground:
            // Session stopped because app went to background
            print("Camera stopped - app in background")

        case .audioDeviceInUseByAnotherClient:
            print("Audio device in use by another client")

        case .videoDeviceInUseByAnotherClient:
            print("Video device in use by another client")

        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            print("Camera not available with multiple foreground apps")

        @unknown default:
            print("Unknown interruption reason")
        }
    }

    @objc func sessionInterruptionEnded(notification: Notification) {
        print("Capture session interruption ended")
        sessionQueue.async {
            self.ensureVideoSessionRunning()
        }
    }

    // MARK: - Orientation
    func startObserverDeviceOrientation() {
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deviceOrientationDidChanged()
        }

        self.deviceOrientationDidChanged()
    }

    func deviceOrientationDidChanged() {
        currentDeviceOrientation = UIDevice.current.orientation
    }
}
// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
extension ErmisCapturer: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let needEncodeAsKeyFrame: Bool = lastDeviceOrientation != currentDeviceOrientation
        if needEncodeAsKeyFrame {
            lastDeviceOrientation = currentDeviceOrientation
            orientationPublisher.send(currentDeviceOrientation)
            log.debug("[Capturer] Did send divice orientaion: \(currentDeviceOrientation.rawValue)")
        }
        videoBufferPublisher.send((sampleBuffer, needEncodeAsKeyFrame))
    }

    func printPCMHex(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == noErr else { return }

        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: length)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        print("PCM HEX:", hex.prefix(200))
    }


    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

    }
}

extension ClientError {
    public final class CannotAddVideoInput: ClientError {}
    public final class CannotAddAudioInput: ClientError {}
}
