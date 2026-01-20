//
// Copyright 2025 Ermis Inc.
//

import Foundation
import AVFoundation
import Combine
import ErmisChat
import UIKit
import AVFAudio
import ErmisCallNode

protocol WebRTCClientDelegate: AnyObject {
}

/// A class manage webrtc connections.
public
class CallNodeClient: NSObject, ObservableObject {
    /// Signaling instance.
    let signaling: SignalingProtocol
    /// CallNodeConnection instance.
    let callNodeConnection: CallNodeConnection
    /// Audio manager instance.
    public var audioManager: ErmisCallAudioManager {
        return ErmisCallAudioManager.shared
    }

    public var voipManager: ErmisVoIPManagerAdvanced?

    public let capturer: ErmisVideoCapturer
    public let player: ErmisPlayer


    public var streamEncoder: StreamEncoder
    public var streamDecoder: StreamDecoder

    public var eventPublisher = PassthroughSubject<CallNodeEventProtocol, Never>()


    /// Current state of io devices.
    var callIOState: CallIOState
    /// The publisher for callIOState.
    public private(set) var callIOStatePublisher = CurrentValueSubject<CallIOState, Never>(.init())
    public private(set) var remoteVideoOrientationPublisher = CurrentValueSubject<VideoOrientation, Never>.init(.init(rotation: 0))

    private let jsonEncoder: JSONEncoder = JSONEncoder()
    private let jsonDecoder: JSONDecoder = JSONDecoder()
    private let ioAccessManager = IOAccessManager()

    public var remoteAddress: String?

    private var cancelBags: Set<AnyCancellable> = []

    weak var delegate: WebRTCClientDelegate?

    private var sendingAudioConfig: Bool = false
    private var hasSentAudioConfig: Bool = false {
        didSet {
            if isReadyToSendAudioFrame {
                streamEncoder.isReadyToEncodeAudio = true
            }
        }
    }
    private var sendingVideoConfig: Bool = false
    private var hasSentVideoConfig: Bool = false {
        didSet {
            if isReadyToSendVideoFrame {
                streamEncoder.isReadyToEncodeVideo = true
            }
        }
    }

    private var isReadyToSendVideoFrame: Bool {
        print("TTTT IS READY: \(callNodeConnection.isConnected), - \(call?.details.state == .connected) - \(hasSentVideoConfig)")
        guard callNodeConnection.isConnected else {
            return false
        }
        guard call?.details.state == .connected else {
            return false
        }
        return hasSentVideoConfig
    }

    private var isReadyToSendAudioFrame: Bool {
//        print("TTTT IS READY: \(callNodeConnection.isConnected), - \(call?.details.state == .connected), - \(hasSentAudioConfig)")
        guard callNodeConnection.isConnected else {
            return false
        }
        guard call?.details.state == .connected else {
            return false
        }
        return hasSentAudioConfig
    }

    public weak var call: Call? {
        didSet {
            do {
                try setAudioEnable(true)
            } catch let error {
                log.error("[Call] Failed to enable audio: \(error)", subsystems: .call)
            }
            do {
                if call?.details.isVideo == true {
                    try setVideoEnabled(true)
                }
            } catch let error {
                log.error("[Call] Failed to enable video: \(error)", subsystems: .call)
            }
        }
    }

    public var currentUserId: String? {
        return call?.details.currentUser?.userId
    }

    public var sessionId: String? {
        return CallManager.shared.sessionId
    }

    private var isVideoCall: Bool {
        return call?.details.isVideo ?? false
    }

    /// Create `callNodeClient` instance.
    ///
    /// - Parameters:
    ///    - signaling: Singaling instance.
    ///    - callNodeConnection: CallNodeConnection instance.
    ///    - audioManager: RTCAudioManager instance.
    /// - Returns: An instance of `callNodeClient` object.
    init(signaling: SignalingProtocol,
         callNodeConnection: CallNodeConnection) {
        self.signaling = signaling
        self.callNodeConnection = callNodeConnection
        self.capturer = ErmisVideoCapturer()
        self.player = ErmisPlayer()
        self.voipManager = ErmisVoIPManagerAdvanced()
        self.streamEncoder = DefaultStreamEncoder()
        self.streamDecoder = DefaultStreamDecoder()
        self.callIOState = CallIOState(isAudioEnabled: true,
                                       isVideoEnabled: false,
                                       isRemoteAudioEnabled: true,
                                       isRemoteVideoEnabled: false)
        super.init()
        setUp()
    }

    /// Convinience way to create `callNodeClient` instance.
    ///
    ///  - Parameters:
    ////    - singaling: `SingalingProtocol` instance.
    ///     - audioManager: `RTCAudioManager` instance.
    /// - Returns: An instance of `callNodeClient` object.
    convenience
    public init?(signaling: SignalingProtocol, relayUrls: [String]) {
        do {
            let callNodeConnection = try CallNodeConnection(relayUrls: relayUrls, secretKey: nil)
            self.init(signaling: signaling,
                      callNodeConnection: callNodeConnection)
        } catch {
            log.error("[Call] Failed to create call node connection with error: \(error)")
            return nil
        }
    }

    deinit {
        log.debug("TTTT CALL NODE CLIENT DEINIT")
    }
    // MARK: - Setup
    private func setUp() {
        signaling.onReceiveCallSignal = { [weak self] callSignal in
            do {
                try self?.handleSignalEvent(callSignal)
            } catch let error {
                log.error("[ErmisCall] handle signal with error: \(error)")
            }
        }
        observerCapturerOutput()
        observerEncoderOutput()
        observerDecoderOutput()
        observerDataChannel()
        observerConnectionState()
        do {
            try streamEncoder.setupVideoEncoder(width: 640, height: 360,
                                                videoCodec: kCMVideoCodecType_HEVC,
                                                audioCodec: .aac,
                                                bitrate: 320_000,
                                                fps: 30)
        } catch {
            log.error("[ErmisCall] Failed to setup stream encoder")
        }

        player.onRequiredKeyframe = { [weak self] in
            self?.sendRequestKeyframeEvent()
        }

        observerAppLifecycleNotifications()
    }

    private func observerAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    private func observerCapturerOutput() {
        capturer.videoBufferPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] (sampleBuffer, isKeyFrame) in
                guard let self else {
                    return
                }
//                log.debug("[CallNode] Received capturer video output frame.")
                self.streamEncoder.encodeVideo(sampleBuffer, isKeyFrame: isReadyToSendVideoFrame ? isKeyFrame : true)
            }
            .store(in: &cancelBags)

        voipManager?.onMicrophoneOutput = { [weak self] (pcmSample, timestamp) in
            self?.streamEncoder.encodeAudio(pcmSample, timestamp: timestamp)
        }

        capturer.orientationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] deviceOrientation in
                guard let self else {
                    return
                }
                let rotationValue = self.previewRotationValue(for: deviceOrientation)
                let videoOrientation = VideoOrientation(rotation:  CGFloat(rotationValue))
                self.callNodeConnection.sendEvent(videoOrientation)
            }
            .store(in: &cancelBags)
    }

    private func observerEncoderOutput() {
        streamEncoder.audioConfigPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                guard let self, let config else {
                    return
                }
//                log.debug("[CallNode] Receive audio config from encoder: \(config)")
                sendAudioConfigIfNeeded(config)
            }
            .store(in: &cancelBags)

        streamEncoder.videoConfigPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                guard let self, let config else {
                    return
                }
//                log.debug("[CallNode] Receive video config from encoder: \(config)")
                sendVideoConfigIfNeeded(config)
            }
            .store(in: &cancelBags)

        streamEncoder.videoKeyFramePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] videoFrame in
                guard let self else {
                    return
                }
                log.debug("[CallNode] Receive video frame from encoder")
                sendVideoFrameIfNeeded(videoFrame)
            }
            .store(in: &cancelBags)

        streamEncoder.videoDeltaFramePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] videoFrame in
                guard let self else {
                    return
                }
//                log.debug("[CallNode] Receive video frame from encoder")
                sendVideoFrameIfNeeded(videoFrame)
            }
            .store(in: &cancelBags)

        streamEncoder.audioFramePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] audioFrame in
//                log.debug("[CallNode] Receive audio frame from encoder")
                guard let self, isReadyToSendAudioFrame else {
                    return
                }
//                log.debug("[CallNode] Send audio frame from encoder")
                callNodeConnection.sendEvent(audioFrame)
            }
            .store(in: &cancelBags)
    }

    private func observerDecoderOutput() {
        streamDecoder.videoBufferPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] (videoBuffer, timestamp) in
                guard let self else {
                    return
                }
//                log.debug("[CallNode] Enqueue video sample buffer.")
                self.player.enqueueVideoSampleBuffer(videoBuffer, timestamp: timestamp)
            }
            .store(in: &cancelBags)

        streamDecoder.audioBufferPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] pcmData in
                guard let self else {
                    return
                }
                //self.player.enqueueAudioSamples(pcmData)
                self.voipManager?.playAudio(pcmData)
            }
            .store(in: &cancelBags)
    }

    private func observerDataChannel() {
        callNodeConnection.dataPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] data in
                guard let self, !data.isEmpty else {
                    return
                }
                let type = CallNodeEventType(with: data[0])
                let payload = Data(data.subdata(in: 1..<data.count))

                switch type {
                case .audioConfig:
                    guard let audioConfig = AudioConfig(payload: payload) else {
                        log.error("[CallNode] Failed to decode audio config event \(data.toString())")
                        return
                    }
                    log.debug("[CallNode] Decode audio config event \(data.toString())")
                    streamDecoder.setAudioConfig(audioConfig)
                case .videoConfig:
                    guard let videoConfig = VideoConfig(payload: payload) else {
                        log.error("[CallNode] Failed to decode video config event \(data.toString())")
                        return
                    }
                    log.debug("[CallNode] Decode video config event \(data.toString())")
                    streamDecoder.setVideoConfig(videoConfig)

                    let videoOrientation = VideoOrientation(rotation: CGFloat(videoConfig.orientation))
                    remoteVideoOrientationPublisher.send(videoOrientation)
                    player.handleDeviceOrientationEvent(VideoOrientation(rotation: CGFloat(videoConfig.orientation)))

                case .audioFrame:
                    guard let audioFrame = AudioFrame(payload: payload) else {
                        log.error("[CallNode] Failed to decode audio frame \(data.toString())")
                        return
                    }
                    streamDecoder.decodeAudioFrame(audioFrame)
                case .videoKeyFrame:
                    guard player.isReadyToPlay else {
                        return
                    }
                    guard let videoFrame = VideoKeyFrame(payload: payload) else {
                        log.error("[CallNode] Failed to decode video key frame \(data.toString())")
                        return
                    }
                    streamDecoder.decodeVideoFrame(data: videoFrame.encodedFrame, timestamp: videoFrame.timestamp)
                case .videoDeltaFrame:
//                    log.debug("TTTT DECODE VIDEO FRAME - \(player.isReadyToPlay)")
                    guard player.isReadyToPlay else {
                        return
                    }
                    guard let videoFrame = VideoDeltaFrame(payload: payload) else {
                        log.error("[CallNode] Failed to decode video delta frame \(data.toString())")
                        return
                    }
//                    log.debug("TTTT DECODE VIDEO FRAME")
                    streamDecoder.decodeVideoFrame(data: videoFrame.encodedFrame, timestamp: videoFrame.timestamp)
                case .orientation:
                    guard let videoOrientation = VideoOrientation(payload: payload) else {
                        log.error("[CallNode] Failed to decode video orientation frame \(data.toString())")
                        return
                    }
                    player.handleDeviceOrientationEvent(videoOrientation)
                    remoteVideoOrientationPublisher.send(videoOrientation)
                case .connected:
                    log.debug("[CallNode] receive connected event")
                    call?.setState(.connected)
                    if isReadyToSendVideoFrame {
                        streamEncoder.isReadyToEncodeVideo = true
                    }
                    if isReadyToSendAudioFrame {
                        streamEncoder.isReadyToEncodeAudio = true
                    }
                case .transciver:
                    log.debug("[CallNode] Receive transciver event")
                    guard let transciverEvent = TransciverEvent(payload: payload) else {
                        log.error("[CallNode] Failed to decode transciver event \(data.toString())")
                        return
                    }
                    let transciverState = transciverEvent.state
                    callIOState.isRemoteAudioEnable = transciverState.audioEnable
                    callIOState.isRemoteVideoEnabled = transciverState.videoEnable
                    if callIOState.isRemoteVideoEnabled {
                        player.isEnable = true
                    } else {
                        player.isEnable = false
                    }
                    callIOStatePublisher.send(callIOState)
                case .requestConfig:
                    log.debug("[CallNode] Receive requestConfig event")
                case .requestKeyframe:
                    log.debug("[CallNode] Receive requestKeyframe event")
                    streamEncoder.forceKeyFrame = true
                case .endCall:
                    log.debug("[CallNode] Receive endcall event")
                    CallManager.shared.clearCall(self.call?.details.callId ?? "", with: .remoteEnded)
                case .unknown:
                    log.debug("[CallNode] failed to decode DataChannelMessage \(data.toString())")
                default:
                    log.debug("[CallNode] failed to decode DataChannelMessage \(data.toString())")
                }
            }
            .store(in: &cancelBags)
    }

    private func observerConnectionState() {
        callNodeConnection.connectionPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else {
                    return
                }
                if status == .connected {
                    log.debug("[CallNode] connection did connected")
                    connectedCallIfAvailable()
                    if let config = streamEncoder.audioConfigPublisher.value {
                        sendAudioConfigIfNeeded(config)
                    }
                    if let config = streamEncoder.videoConfigPublisher.value {
                        sendVideoConfigIfNeeded(config)
                    }
                    sendTrascriptionStateMessage()
                }
            }
            .store(in: &cancelBags)
    }

    private func connectedCallIfAvailable() {
        guard callNodeConnection.isConnected else {
            log.debug("[CallNode] Call not ready to connect, callNodeConnected: \(callNodeConnection.isConnected)")
            return
        }
        Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }
            do {
                log.debug("[CallNode] Sending connected call signal")
                try await self.sendConnectedCallSignal()
                log.debug("[CallNode] Sending connected call event")
                try? await self.callNodeConnection.sendControlFrame(CallConnected().data)
                DispatchQueue.main.async {
                    self.call?.setState(.connected)
                    if self.hasSentVideoConfig {
                        self.streamEncoder.isReadyToEncodeVideo = true
                    }
                    if self.hasSentAudioConfig {
                        self.streamEncoder.isReadyToEncodeAudio = true
                    }
                }
                ErmisCallAudioManager.shared.configureAudioSession(
                    isIncomingCall: call?.details.isIncoming ?? false,
                    isVideoCall: call?.details.isVideo ?? false)

            } catch let error {
                log.error("[Call] failed to sent connect signal: \(error)", subsystems: .call)
                await CallManager.shared.endCall(with: self.call?.details.callId ?? "")
                return
            }
        }
    }

    private func sendVideoFrameIfNeeded(_ event: CallNodeEventProtocol) {
        if isReadyToSendVideoFrame {
            callNodeConnection.sendEvent(event)
        }
    }

    private func sendAudioConfigIfNeeded(_ config: AudioConfig) {
        if callNodeConnection.isConnected, !sendingAudioConfig, !hasSentAudioConfig {
            sendingAudioConfig = true
            Task(name: "call_node_send_config", priority: .high) {
                do {
                    try await self.callNodeConnection.sendControlFrame(config.data)
                    DispatchQueue.main.async {
                        self.sendingAudioConfig = false
                        self.hasSentAudioConfig = true
                    }
                    log.debug("[CallNode] Sent audio config: \(config)")
                } catch {
                    DispatchQueue.main.async {
                        self.sendingAudioConfig = false
                        self.hasSentAudioConfig = false
                    }
                    log.debug("[CallNode] Sent audio config failed: \(error)")
                }
            }
        }
    }

    private func sendVideoConfigIfNeeded(_ config: VideoConfig) {
        if callNodeConnection.isConnected, !sendingVideoConfig, !hasSentVideoConfig {
            var config = config
            let orientation = self.capturer.currentDeviceOrientation
            let rotation = self.previewRotationValue(for: orientation)
            config.orientation = Int(rotation)
            DispatchQueue.main.async {
                self.sendingVideoConfig = true
            }
            Task(name: "call_node_send_config", priority: .high) {
                do {
                    try await self.callNodeConnection.sendControlFrame(config.data)
                    DispatchQueue.main.async {
                        self.sendingVideoConfig = false
                        self.hasSentVideoConfig = true
                    }
                    log.debug("[CallNode] Sent video config: \(config)")
                } catch {
                    DispatchQueue.main.async {
                        self.sendingVideoConfig = false
                        self.hasSentVideoConfig = false
                    }
                    log.debug("[CallNode] Sent video config failed: \(error)")
                }
            }
        }
    }

    // MARK: - App lifecycle
    @objc private func appWillResignActive() {
        log.debug("[CallNode] Call node client app will resign active", subsystems: .call)
        streamEncoder.appWillResignActive()
        capturer.appWillResignActive()
        player.appWillResignActive()
    }

    @objc private func appDidEnterBackground() {
        log.debug("[CallNode] Call node client app did enter background", subsystems: .call)
        streamEncoder.appDidEnterBackground()
        capturer.appDidEnterBackground()
        player.appDidEnterBackground()
    }

    @objc private func appDidBecomeActive() {
        log.debug("[CallNode] Call node client app did become active", subsystems: .call)
        streamEncoder.appDidBecomeActive()
        capturer.appDidBecomeActive()
        player.appDidBecomeActive()
    }

    // MARK: - Action
    package func startIO() {
        capturer.startCapturer(call?.details.isVideo ?? false)
        player.setupPlayerIfNeeded()
        do {
            try voipManager?.start()
        } catch {
            log.error("[CallNode] Failed to start VoIP manager: \(error)")
        }
    }

    package func didActiveAudioSession() {
        self.startIO()
        call?.audioManager.didActivateAudioSession()
    }

    package func didDeactiveAudioSession() {
        call?.audioManager.didDeactivateAudioSession()
        capturer.stopCapturer()
    }
    /// Toggle video enable state.
    public func toggleVideo() {
        let isEnable = callIOState.isVideoEnabled
        setVideoEnabled(!isEnable)
    }

    /// Toggle audio enable state.
    func toggleAudio() {
        let isEnable = callIOState.isAudioEnabled
        setAudioEnable(!isEnable)
    }

    /// Toggle camera position state.
    ///
    ///  - Returns: Throws `Error` if not success.
    func toggleCameraPosition() throws {
        try setCameraPosition(callIOState.cameraPosition.flip())
    }

    /// Set video enable state
    ///
    /// - Parameters:
    ///    - isEnable: The enable state of video want to set.
    public func setVideoEnabled(_ isEnable: Bool) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if !isEnable {
                try await stopVideoCapture()
                callIOState.isVideoEnabled = false
                callIOStatePublisher.send(callIOState)
                sendTrascriptionStateMessage()
            } else {
                let isCameraAvailable = await ioAccessManager.requestCameraAccessIfNeeded()
                guard isCameraAvailable else {
                    setVideoEnabled(false)
                    return
                }
                try await setCameraPosition(callIOState.cameraPosition)
                try await sendUpgradeCallIfNeeded()
                callIOState.isVideoEnabled = true
                callIOStatePublisher.send(callIOState)
                sendTrascriptionStateMessage()
            }
        }
    }

    /// Set video enable state
    ///
    /// - Parameters:
    ///    - isEnable: The enable state of audio want to set.
    public func setAudioEnable(_ isEnable: Bool) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if !isEnable {
                callIOState.isAudioEnabled = false
                voipManager?.setMicrophoneEnabled(false)
            } else {
                let isMicrophoneAccessGranted = await ioAccessManager.requestMicrophoneAccessIfNeeded()
                guard isMicrophoneAccessGranted else {
                    log.debug("[CallNode] Don't have mic permission")
                    voipManager?.setMicrophoneEnabled(false)
                    callIOState.isAudioEnabled = false
                    return
                }
                guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                    return
                }
                do {
                    voipManager?.setMicrophoneEnabled(true)
                    callIOState.isAudioEnabled = true
                } catch {
                    log.warning("[CallNode] Failed to add audio input: \(error)")
                    return
                }
            }
            callIOStatePublisher.send(callIOState)
            sendTrascriptionStateMessage()
            log.debug("[WebRTC] setAudioEnable: \(isEnable)")
        }
    }

    /// Send callIOState via WebRTC data channel.
    func sendTrascriptionStateMessage() {
        let transciverState = TransciverState(audioEnable: callIOState.isAudioEnabled,
                                              videoEnable: callIOState.isVideoEnabled)
        let tranciverEvent = TransciverEvent(state: transciverState)
        callNodeConnection.sendEvent(tranciverEvent)
    }

    /// Send message via WebRTC data channel.
    ///
    /// - Parameters:
    ///    - message: The message to send.
    /// - Returns: A boolean value, `true` if message send success.
    func sendEndcallEvent() -> Bool {
        guard callNodeConnection.isConnected else {
            return false
        }
        let data = Data(bytes: [CallNodeEventType.endCall.rawValue])
        Task(name: "call_node_send_event", priority: .high) {
            do {
                try await callNodeConnection.sendControlFrame(data)
            } catch {
                log.error("[CallNode] Failed to end call event: \(error)", subsystems: .call)
            }
        }
        return true
    }

    public func sendRequestKeyframeEvent() {
        guard callNodeConnection.isConnected else {
            return
        }
        let data = Data(bytes: [CallNodeEventType.requestKeyframe.rawValue])
        Task(name: "call_node_send_event", priority: .high) {
            do {
                try await callNodeConnection.sendControlFrame(data)
            } catch {
                log.error("[CallNode] Failed to end call event: \(error)", subsystems: .call)
            }
        }
        return
    }

    func isCallNodeConnected() -> Bool {
        return callNodeConnection.getConnectionState()
    }

    func getConnectionStats() -> ConnectionStats {
        return callNodeConnection.getConnectionStats()
    }

    // MARK: - Video
    /// Start capture video.
    ///
    /// - Parameters:
    ///    - device: The capture device.
    /// - Returns: Throws error if not successful.
    public
    func startCapture(device: AVCaptureDevice?) throws {
        guard let device else {
            return
        }
        try capturer.addVideoInput(device)
    }

    /// Stop capture video.
    ///
    ///  - Returns: Throws error if not successful.
    public
    func stopVideoCapture() throws {
        capturer.removeVideoInput()
    }

    /// Set camera position and capture video.
    ///
    /// - Parameters:
    ///    - position: Position of camera want to use.
    /// - Returns: Throws error if not successful.
    public
    func setCameraPosition(_ position: CameraPosition) throws {
        guard let device = capturer.videoCapturerDevice(for: position.captureDevicePosition) else {
            return
        }
        try startCapture(device: device)
        callIOState.cameraPosition = position
    }

    // MARK: - Signal
    /// Create a new call.
    ///
    /// - Parameters:
    ///    - isVideo: `true` if this call is video call.
    /// - Returns: Throws error if not successful.
    public func createCall(_ isVideo: Bool, sessionId: String) async throws {
        if callNodeConnection.isConnected {
            callNodeConnection.close()
        }
        guard let localAddress = await callNodeConnection.localAddress else {
            return
        }
        let metaData = Metadata(localAddress: localAddress)
        log.debug("[CallNode] Sending create call signal.")
        let callSignalPayload = try await signaling.sendSignal(sessionId: sessionId,
                                                               callId: nil,
                                                               action: .createCall,
                                                               isVideo: isVideo,
                                                               signalType: .none,
                                                               sdp: "",
                                                               metadata: metaData)
        if call?.isLocalId == true {
            call?.setRemoteCallId(callSignalPayload.callId)
        }

        DispatchQueue.main.async {
            self.call?.setState(.ringing)
        }
        Task.detached(name: "call_accept_connection", priority: .high) { [weak self] in
            do {
                try await self?.callNodeConnection.acceptConnect()
            } catch {
                log.error("[CallNode] Failed to accept connection \(error)")
                CallManager.shared.endCall(with: self?.call?.details.callId ?? "")
            }
        }
    }

    /// Send upgrade signal to change from audio call to video call.
    ///
    /// - Returns: Throws error if not successful.
    public func sendUpgradeCallIfNeeded() async throws {
        guard !isVideoCall else {
            return
        }
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .upgradeCall,
                                       isVideo: true,
                                       signalType: nil,
                                       sdp: nil,
                                       metadata: nil)
    }

    /// Send health call signal. If server don't receive this signal for amount
    /// of time, this call will be ended by server.
    ///
    /// - Returns: Throws error if not successful.
    public func sendHealthCallSignal() async throws {
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .healthCall,
                                       isVideo: isVideoCall,
                                       signalType: nil,
                                       sdp: nil,
                                       metadata: nil)
    }

    /// Send connected signal. This signal needs to send when first time peer
    /// connection connected.
    ///
    /// - Returns: Throws error if not successful.
    public func sendConnectedCallSignal() async throws {
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .connectCall,
                                       isVideo: isVideoCall,
                                       signalType: nil,
                                       sdp: nil,
                                       metadata: nil)
    }

    /// Send accept call signal.
    ///
    /// - Returns: Throws error if not successful.
    public func acceptCall() async throws {
        guard let remoteAddress else {
            return
        }
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .acceptCall,
                                       isVideo: isVideoCall,
                                       signalType: nil,
                                       sdp: nil,
                                       metadata: nil)
//        try await self.callNodeConnection.connect(to: remoteAddress)
    }

    /// Send reject call signal.
    ///
    /// - Returns: Throws error if not successful.
    public func rejectCall() async throws {
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .rejectCall,
                                       isVideo: isVideoCall,
                                       signalType: nil,
                                       sdp: nil,
                                       metadata: nil)
    }

    /// Stop current call and send endcall signal.
    ///
    /// - Returns: Throws error if not successful.
    public func endCall() async throws {
        if call?.isMissed == true {
            try await signaling.sendSignal(sessionId: sessionId,
                                           callId: call?.details.callId,
                                           action: .missCall,
                                           isVideo: isVideoCall,
                                           signalType: nil,
                                           sdp: nil, metadata: nil)
        } else {
            try await signaling.sendSignal(sessionId: sessionId,
                                           callId: call?.details.callId,
                                           action: .endCall,
                                           isVideo: isVideoCall,
                                           signalType: nil,
                                           sdp: nil, metadata: nil)
        }
    }

    public func connectToRemote() async throws {
        guard let remoteAddress else {
            throw ClientError("[CallNode] No remote address to connect to.")
        }
        try await self.callNodeConnection.connect(to: remoteAddress)
        log.debug("[CallNode] Connected to remote: \(remoteAddress)")
    }

    public func stop() {
        setAudioEnable(false)
        setVideoEnabled(false)
    }

    /// Stop IO and close peerconnection.
    /// - Note: This will not send end call signal to other device
    public func close() {
        self.remoteAddress = nil
        if call?.details.isIncoming == false {
            try? audioManager.didDeactivateAudioSession()
        }
        capturer.stopCapturer()
        player.stop()
        voipManager?.stop()
        if call?.details.state != .ended {
            Task(priority: .userInitiated) {
                try? await sendEndcallEvent()
                callNodeConnection.close()
            }
        } else {
            callNodeConnection.close()
        }
    }

    /// Handle received signal event.
    ///
    /// - Parameters:
    ///    - callSignal: The received signal to handle.
    /// - Returns: Throws error if not successful.
    func handleSignalEvent(_ callSignal: CallSignalEvent) throws {
        log.debug("receive callID: \(callSignal.callId), action: \(callSignal.callAction), signalType: \(callSignal.signal?.type)")
        guard callSignal.callId == call?.details.callId else {
            log.error("[ErmisCall] Receive invalid signal action: \(callSignal.callAction), callId: \(callSignal.callId), current call: \(call)")
            return
        }

        guard callSignal.sessionId != sessionId else {
            log.debug("[ErmisCall] Receive signal from self, ignore it.")
            return
        }

        guard callSignal.userId != currentUserId else {
            return
        }

        switch callSignal.callAction {
        case .createCall:
            guard let localAddress = callSignal.metadata?.address else {
                return
            }
            self.remoteAddress = localAddress
        case .acceptCall:
            break
        case .rejectCall:
            call?.setState(.ended)
            CallManager.shared.clearCall(callSignal.callId, with: .remoteEnded)
//            try? close()
            break
        case .missCall:
            call?.setState(.ended)
            CallManager.shared.clearCall(callSignal.callId, with: .unanswered)
//            try? close()
            break
        case .connectCall:
            log.debug("[CallNode] Receive connected signal.")
            DispatchQueue.main.async {
                self.call?.setState(.connected)
                if self.isReadyToSendVideoFrame {
                    self.streamEncoder.isReadyToEncodeVideo = true
                }
                if self.isReadyToSendAudioFrame {
                    self.streamEncoder.isReadyToEncodeAudio = true
                }
            }
        case .healthCall:
            break
        case .endCall:
            call?.setState(.ended)
            CallManager.shared.clearCall(callSignal.callId, with: .remoteEnded)
//            try? close()
        case .signalCall:
            break
        case .upgradeCall:
            call?.details.isVideo = true
        }
    }

//    // MARK: - Helper
    private func previewRotationValue(for orientation: UIDeviceOrientation) -> UInt32 {
        switch orientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        case .unknown:
            return 90
        @unknown default:
            return 0
        }
    }
}
