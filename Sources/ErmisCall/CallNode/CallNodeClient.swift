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

    public let capturer: ErmisCapturer
    public let player: ErmisPlayer


    public var streamEncoder: StreamEncoder

    public var eventPublisher = PassthroughSubject<CallNodeEventProtocol, Never>()


    /// Current state of io devices.
    private var callIOState: CallIOState
    /// The publisher for callIOState.
    public private(set) var callIOStatePublisher = CurrentValueSubject<CallIOState, Never>(.init())

    private let jsonEncoder: JSONEncoder = JSONEncoder()
    private let jsonDecoder: JSONDecoder = JSONDecoder()
    private let ioAccessManager = IOAccessManager()

    public var remoteAddress: String?

    private var cancelBags: Set<AnyCancellable> = []

    weak var delegate: WebRTCClientDelegate?

    private var sendingAudioConfig: Bool = false
    private var hasSentAudioConfig: Bool = false {
        didSet {
            if isReadyToSendFrame {
                streamEncoder.isReadyToEncode = true
            }
        }
    }
    private var sendingVideoConfig: Bool = false
    private var hasSentVideoConfig: Bool = false {
        didSet {
            if isReadyToSendFrame {
                streamEncoder.isReadyToEncode = true
            }
        }
    }

    private var isReadyToSendFrame: Bool {
        guard callNodeConnection.isConnected else {
            return false
        }
        guard call?.details.state == .connected else {
            return false
        }
        if call?.details.isVideo == true {
            return hasSentVideoConfig && hasSentAudioConfig
        } else {
            return hasSentAudioConfig
        }
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
        return call?.sessionId
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
        self.capturer = ErmisCapturer()
        self.player = ErmisPlayer()
        self.streamEncoder = DefaultStreamEncoder()
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
    // MARK: - Setup
    private func setUp() {
        signaling.onReceiveCallSignal = { [weak self] callSignal in
            Task {
                do {
                    try await self?.handleSignalEvent(callSignal)
                } catch let error {
                    log.error("[ErmisCall] handle signal with error: \(error)")
                }
            }
        }
        observerCapturerOutput()
        observerEncoderOutput()
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
    }

    private func observerCapturerOutput() {
        capturer.videoBufferPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] (sampleBuffer, isKeyFrame) in
                guard let self else {
                    return
                }
//                log.debug("[CallNode] Received capturer video output frame.")
                self.streamEncoder.encodeVideo(sampleBuffer, isKeyFrame: isReadyToSendFrame ? isKeyFrame : true)
            }
            .store(in: &cancelBags)

        capturer.audioBufferPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] sampleBuffer in
//                log.debug("[CallNode] Received capturer audio output frame.")
                self?.streamEncoder.encodeAudio(sampleBuffer)
                
            }
            .store(in: &cancelBags)

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
                sendVideoConfigIfNeeded(config)
            }
            .store(in: &cancelBags)

        streamEncoder.videoKeyFramePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] videoFrame in
                guard let self else {
                    return
                }
                sendVideoFrameIfNeeded(videoFrame)
            }
            .store(in: &cancelBags)

        streamEncoder.videoDeltaFramePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] videoFrame in
                guard let self else {
                    return
                }
                sendVideoFrameIfNeeded(videoFrame)
            }
            .store(in: &cancelBags)

        streamEncoder.audioFramePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] audioFrame in
                guard let self, isReadyToSendFrame else {
                    return
                }
                callNodeConnection.sendEvent(audioFrame)
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
                switch type {
                case .audioConfig, .videoConfig, .audioFrame, .videoKeyFrame, .videoDeltaFrame, .orientation:
                    do {
                        player.parseEvent(data)
                    } catch {
                        log.debug("[CallNode] failed to decode DataChannelMessage \(data.toString())")
                    }
                case .connected:
                    call?.setState(.connected)
                    if isReadyToSendFrame {
                        streamEncoder.isReadyToEncode = true
                    }
                    log.debug("[CallNode] Received connected event")
                case .transciver:
                    let payload = Data(data.subdata(in: 1..<data.count))
                    guard let transciverEvent = TransciverEvent(payload: payload) else {
                        log.error("[CallNode] Failed to decode transciver event \(data.toString())")
                        return
                    }
                    let transciverState = transciverEvent.state
                    callIOState.isRemoteAudioEnable = transciverState.audioEnable
                    callIOState.isRemoteVideoEnabled = transciverState.videoEnable
                    callIOStatePublisher.send(callIOState)
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
                    Task {
                            do {
                                try await self.sendConnectedCallSignal()
                                try await self.callNodeConnection.sendControlFrame(CallConnected().data)
                                DispatchQueue.main.async {
                                    self.call?.setState(.connected)
                                    if self.isReadyToSendFrame {
                                        self.streamEncoder.isReadyToEncode = true
                                    }
                                }
                                let orientation = self.capturer.currentDeviceOrientation
                                let rotation = self.previewRotationValue(for: orientation)
                                let videoOrientation = VideoOrientation(rotation: CGFloat(rotation))
                                try await self.callNodeConnection.sendEvent(videoOrientation)
                            } catch let error {
                                log.error("[Call] failed to sent connect signal: \(error)", subsystems: .call)
                                await CallManager.shared.endCall(self.call)
                                return
                            }
                    }
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

    private func sendVideoFrameIfNeeded(_ event: CallNodeEventProtocol) {
        if isReadyToSendFrame {
            callNodeConnection.sendEvent(event)
        }
    }

    private func sendAudioConfigIfNeeded(_ config: AudioConfig) {
        if callNodeConnection.isConnected, !sendingAudioConfig, !hasSentAudioConfig {
            sendingAudioConfig = true
            Task(name: "call_node_send_config", priority: .high) {
                do {
                    try await self.callNodeConnection.sendControlFrame(config.data)
                    self.sendingAudioConfig = false
                    self.hasSentAudioConfig = true
                    log.debug("[CallNode] Sent audio config: \(config)")
                } catch {
                    self.sendingAudioConfig = false
                    self.hasSentAudioConfig = false
                    log.debug("[CallNode] Sent audio config failed: \(error)")
                }
            }
        }
    }

    private func sendVideoConfigIfNeeded(_ config: VideoConfig) {
        if callNodeConnection.isConnected, !sendingVideoConfig, !hasSentVideoConfig {
            sendingVideoConfig = true
            Task(name: "call_node_send_config", priority: .high) {
                do {
                    try await self.callNodeConnection.sendControlFrame(config.data)
                    self.sendingVideoConfig = false
                    self.hasSentVideoConfig = true
                    log.debug("[CallNode] Sent video config: \(config)")
                } catch {
                    self.sendingVideoConfig = false
                    self.hasSentVideoConfig = false
                    log.debug("[CallNode] Sent video config failed: \(error)")
                }
            }
        }
    }

    // MARK: - Action
    package func startIO() {
        capturer.startCapturer(true, true)
        player.setupPlayerIfNeeded()
//        if call?.details.isVideo == true {
//            call?.audioManager.changeAudioPort(to: .builtInSpeaker)
//        } else {
//            call?.audioManager.changeAudioPort(to: .builtInReceiver)
//        }
    }

    package func didActiveAudioSession() {
        call?.audioManager.didActivateAudioSession()
        if call?.audioManager.currentPort == nil {
            call?.audioManager.setOverrideOutputPort(isSpeaker: call?.details.isVideo == true)
        }
        self.startIO()
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
    func toggleCameraPosition() async throws {
        try await setCameraPosition(callIOState.cameraPosition.flip())
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
                capturer.removeAudioInput()
            } else {
                let isMicrophoneAccessGranted = await ioAccessManager.requestMicrophoneAccessIfNeeded()
                guard isMicrophoneAccessGranted else {
                    setAudioEnable(false)
                    return
                }
                guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                    return
                }
                do {
                    try capturer.addAudioInput(audioDevice)
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
    func sendMessage(_ message: DataChannelMessage) -> Bool {
        guard callNodeConnection.isConnected else {
            return false
        }
        do {
            var data = try JSONEncoder().encode(message)
            var type: UInt8
            switch message {
            case .endCall:
                type = 7
            }
            data.insert(type, at: 0)
            Task(name: "call_node_send_event", priority: .high) {
                do {
                    try await callNodeConnection.sendControlFrame(data)
                } catch {
                    log.error("[CallNode] Failed to send data message: \(message) with error: \(error)", subsystems: .call)
                }
            }
            return true
        } catch {
            log.error("[WebRTC] error when encoding message: \(message)", subsystems: .webRTC)
            return false
        }
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
    func startCapture(device: AVCaptureDevice?) async throws {
        guard let device else {
            return
        }
        try capturer.addVideoInput(device)
    }

    /// Stop capture video.
    ///
    ///  - Returns: Throws error if not successful.
    public
    func stopVideoCapture() async throws {
        capturer.removeVideoInput()
    }

    /// Set camera position and capture video.
    ///
    /// - Parameters:
    ///    - position: Position of camera want to use.
    /// - Returns: Throws error if not successful.
    public
    func setCameraPosition(_ position: CameraPosition) async throws {
        guard let device = capturer.videoCapturerDevice(for: position.captureDevicePosition) else {
            return
        }
        try await startCapture(device: device)
        callIOState.cameraPosition = position
    }

    // MARK: - Signal
    /// Create a new call.
    ///
    /// - Parameters:
    ///    - isVideo: `true` if this call is video call.
    /// - Returns: Throws error if not successful.
    public func createCall(_ isVideo: Bool, sessionId: String) async throws {
        guard let localAddress = await callNodeConnection.localAddress else {
            return
        }
        let metaData = Metadata(localAddress: localAddress)
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
        Task.detached(name: "call_accept_connection", priority: .high) {
            do {
                try await self.callNodeConnection.acceptConnect()
            } catch {
                log.error("[CallNode] Failed to accept connection \(error)")
            }
        }
    }

//    /// Create and send offer signal to other.
//    ///
//    /// - Returns: Throws error if not successful.
//    public func sendOffer() async throws {
//        let sdp = try await peerConnection.createOffer(with: .default)
//        try await signaling.sendSignal(sessionId: sessionId,
//                                       callId: call?.details.callId,
//                                       action: .signalCall,
//                                       isVideo: isVideoCall,
//                                       signalType: .offer, sdp: sdp.sdp)
//        log.debug("[WebRTC] Send offer callID: \(call?.details.callId ?? "")")
//    }
//
//    /// Create and send answer signal to other.
//    ///
//    /// - Returns: Throws error if not successful.
//    public func sendAnswer() async throws {
//        let sdp = try await peerConnection.createAnswer(with: .default)
//        try await signaling.sendSignal(sessionId: sessionId,
//                                       callId: call?.details.callId,
//                                       action: .signalCall,
//                                       isVideo: isVideoCall,
//                                       signalType: .answer,
//                                       sdp: sdp.sdp)
//        log.debug("[WebRTC] Send answer callID: \(call?.details.callId ?? "")")
//    }

//    /// Sending all current pending ices to other.
//    ///
//    /// - Returns: Throws error if not successful.
//    public func sendPendingIces() async throws {
//        for ice in pendingLocalICE {
//            try await signaling.sendSignal(sessionId: sessionId,
//                                           callId: call?.details.callId,
//                                           action: .signalCall,
//                                           isVideo: isVideoCall,
//                                           signalType: .ice,
//                                           sdp: ice.sdpString)
//        }
//    }

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
        Task.detached(name: "call_connect", priority: .high) {
            try await self.callNodeConnection.connect(to: remoteAddress)
            self.call?.details.state = .connected
        }
    }

    /// Send reject call signal.
    ///
    /// - Returns: Throws error if not successful.
    public func rejectCall() async throws {
        setAudioEnable(false)
        setVideoEnabled(false)
        guard call?.details.state != .ended else {
            return
        }
        try? await sendMessage(.endCall)
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .rejectCall,
                                       isVideo: isVideoCall,
                                       signalType: nil,
                                       sdp: nil,
                                       metadata: nil)
        capturer.stopCapturer()
        callNodeConnection.close()
    }

    /// Stop current call and send endcall signal.
    ///
    /// - Returns: Throws error if not successful.
    public func endCall() async throws {
        defer {
            capturer.stopCapturer()
            callNodeConnection.close()
        }
        setAudioEnable(false)
        setVideoEnabled(false)
        if call?.details.isIncoming == false {
            try audioManager.didDeactivateAudioSession()
        }
        guard call?.details.state != .ended else {
            return
        }
        try? await sendMessage(.endCall)
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

    /// Stop IO and close peerconnection.
    /// - Note: This will not send end call signal to other device
    func close() {
        setAudioEnable(false)
        setVideoEnabled(false)
        if call?.details.isIncoming == false {
            try? audioManager.didDeactivateAudioSession()
        }
        capturer.stopCapturer()
        callNodeConnection.close()
    }

    /// Handle received signal event.
    ///
    /// - Parameters:
    ///    - callSignal: The received signal to handle.
    /// - Returns: Throws error if not successful.
    func handleSignalEvent(_ callSignal: CallSignalEvent) async throws {
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
            if call?.details.state == .ringing {
                call?.setState(.connecting)
            }
//            try await sendOffer()
        case .rejectCall:
            call?.setState(.ended)
            Task {
                try? await endCall()
            }
        case .missCall:
            call?.setState(.ended)
            Task {
                try? await endCall()
            }
        case .connectCall:
            call?.setState(.connected)
            if isReadyToSendFrame {
                streamEncoder.isReadyToEncode = true
            }
        case .healthCall:
            break
        case .endCall:
            call?.setState(.ended)
            Task {
                try? await endCall()
            }
        case .signalCall:
            break
        case .upgradeCall:
            call?.details.isVideo = true
        }
    }

    /// Handle received data channel message from WebRTC data channel.
    ///
    /// - Parameters:
    ///    - message: The received data channel message to handle.
    func handleDataChannelMessage(_ message: DataChannelMessage) {
        switch message {
        case .endCall:
            call?.setState(.ended)
            Task {
                await  CallManager.shared.endCall(call)
            }
            Task {
                try? await endCall()
            }
            break
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
            return 0
        @unknown default:
            return 0
        }
    }
}
