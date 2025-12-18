//
// Copyright 2025 Ermis Inc.
//

import UIKit
import AVFoundation
import Combine
import ErmisChat

public class ErmisCapturer: NSObject, AppLifecycleObserver {
    public let videoCaptureSession = AVCaptureSession()
    public let audioCaptureSession = AVCaptureSession()

    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private let sessionQueue = DispatchQueue(label: "network.ermis.session")
    private let videoQueue = DispatchQueue(label: "network.ermis.video")
    private let audioQueue = DispatchQueue(label: "network.ermis.audio")


    private var preset: AVCaptureSession.Preset = .iFrame960x540

    var lastDeviceOrientation: UIDeviceOrientation = .portrait
    var currentDeviceOrientation: UIDeviceOrientation = .portrait

    private let desiredFPS: Float64 = 30

    public var audioBufferPublisher = PassthroughSubject<CMSampleBuffer, Never>()
    public var videoBufferPublisher = PassthroughSubject<(CMSampleBuffer, Bool), Never>()
    public var orientationPublisher = PassthroughSubject<UIDeviceOrientation, Never>()

    private var isReadyToStart: Bool = false
    private var isVideoSessionRunning: Bool = false
    private var isAudioSessionRunning: Bool = false
    private let videoSessionLock = NSLock()
    private let audioSessionLock = NSLock()

    public override init() {
        super.init()
        setup()
        startObserverDeviceOrientation()
        startObserverNotifications()
    }

    deinit {
        log.debug("TTTT CAPTURER CLIENT DEINIT")
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

        // Setup audio output
        self.audioOutput = AVCaptureAudioDataOutput()
        self.audioOutput?.setSampleBufferDelegate(self, queue: self.audioQueue)
        if let audioOutput = self.audioOutput, self.audioCaptureSession.canAddOutput(audioOutput) {
            self.audioCaptureSession.addOutput(audioOutput)
            log.debug("[Capturer] Audio output added to session")
        } else {
            log.error("[Capturer] Audio output not added to session")
        }


    }

    func startCapturer(_ isAudioEnable: Bool, _ isVideoEnable: Bool) {
        getCurrentAppState()
        isReadyToStart = true
        isVideoSessionRunning = isVideoEnable
        isAudioSessionRunning = isAudioEnable

        sessionQueue.async {
            if isVideoEnable {
                log.debug("[Capturer] Start video capture")
                self.videoCaptureSession.startRunning()
            }

            if isAudioEnable {
                log.debug("[Capturer] Start audio capture")
                self.audioCaptureSession.startRunning()
            }
        }
    }

    private func getCurrentAppState() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let state = scene.activationState

            switch state {
            case .foregroundActive:
                print("TTTT Foreground & active")
            case .foregroundInactive:
                print("TTTT Foreground but inactive")
            case .background:
                print("TTTT Background")
            @unknown default:
                break
            }
        }
    }

    func stopCapturer() {
        isVideoSessionRunning = false
        isAudioSessionRunning = false
        log.debug("[Capturer] Stop audio, video capture")
        self.audioCaptureSession.stopRunning()
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

    public func addAudioInput(_ device: AVCaptureDevice) throws {
        if let audioInput {
            if audioInput.device != device {
                audioCaptureSession.removeInput(audioInput)
            } else {
                sessionQueue.async {
                    self.ensureAudioSessionRunning()
                }
            }
        }

        // Add new input
        guard let audioInput = try? AVCaptureDeviceInput(device: device),
              audioCaptureSession.canAddInput(audioInput) else {
            return
        }

        sessionQueue.async {
            self.audioSessionLock.lock()
            self.audioCaptureSession.beginConfiguration()
            self.audioCaptureSession.addInput(audioInput)
            self.audioInput = audioInput
            log.debug("[Capturer] Add audio input")
            self.audioCaptureSession.commitConfiguration()
            self.audioSessionLock.unlock()

            self.ensureAudioSessionRunning()
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

    private func ensureAudioSessionRunning() {
        if self.isReadyToStart, !self.isAudioSessionRunning {
            self.isAudioSessionRunning = true
            log.debug("[Capturer] Start audio capture")
            self.audioSessionLock.lock()
            self.audioCaptureSession.startRunning()
            self.audioSessionLock.unlock()
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

    public func removeAudioInput() {
        guard let audioInput, isAudioSessionRunning else {
            return
        }
        audioCaptureSession.removeInput(audioInput)
        self.audioInput = nil
        isAudioSessionRunning = false
        sessionQueue.async {
            self.audioSessionLock.lock()
            log.debug("[Capturer] Remove audio input")
            self.audioCaptureSession.stopRunning()
            self.audioSessionLock.unlock()
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
        isVideoSessionRunning = false
    }

    @objc func sessionWasInterrupted(notification: Notification) {
        isVideoSessionRunning = false
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
        ensureVideoSessionRunning()
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
        if output == videoOutput {
            let needEncodeAsKeyFrame: Bool = lastDeviceOrientation != currentDeviceOrientation
            if needEncodeAsKeyFrame {
                lastDeviceOrientation = currentDeviceOrientation
                orientationPublisher.send(currentDeviceOrientation)
                log.debug("[Capturer] Did send divice orientaion: \(currentDeviceOrientation.rawValue)")
            }
            videoBufferPublisher.send((sampleBuffer, needEncodeAsKeyFrame))
        } else if output == audioOutput {
//            printPCMHex(from: sampleBuffer)
            audioBufferPublisher.send(sampleBuffer)
        }
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
