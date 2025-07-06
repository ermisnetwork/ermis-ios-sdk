//
// Copyright 2025 Ermis Inc.
//

import StreamWebRTC
import ErmisChat
import Combine

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClientDidReciveHealthCallMessage(_ webRTCClient: WebRTCClient)
}

/// A class manage webrtc connections.
public
class WebRTCClient: NSObject, ObservableObject {
    /// Peer connection factory instance.
    let factory: PeerConnectionFactory
    /// Signaling instance.
    let signaling: SignalingProtocol
    /// Peer connection instance.
    let peerConnection: PeerConnection
    /// Audio manager instance.
    let audioManager: RTCAudioManager

    /// The local audio track.
    public private(set) var localAudioTrack: RTCAudioTrack?
    /// The local audio track.
    public private(set) var videoCapturer: RTCVideoCapturer?
    /// The local video track.
    public private(set) var localVideoTrack: RTCVideoTrack?
    /// The remote video track.
    public private(set) var remoteVideoTrack: RTCVideoTrack?
    /// The local data channel.
    public private(set) var localDataChannel: RTCDataChannel?
    /// The remote data channel.
    public private(set) var remoteDataChannel: RTCDataChannel?

    /// Current state of io devices.
    private var callIOState: CallIOState
    /// The publisher for remoteVideoTrack.
    public private(set) var remoteVideoTrackPublisher = CurrentValueSubject<RTCVideoTrack?, Never>(nil)
    /// The publisher for callIOState.
    public private(set) var callIOStatePublisher = CurrentValueSubject<CallIOState, Never>(.init())
    /// The pending ices, this will be sent when peerConnection remote SDP is set.
    public private(set) var pendingLocalICE: [ICECandidate] = []
    /// Flag to check when ice is ready to sent or not.
    var isReadyToSendICE: Bool = false

    private let jsonEncoder: JSONEncoder = JSONEncoder()
    private let jsonDecoder: JSONDecoder = JSONDecoder()
    private let ioAccessManager = IOAccessManager()

    weak var delegate: WebRTCClientDelegate?

    public weak var call: Call? {
        didSet {
            Task {
                do {
                    try setAudioEnable(true)
                } catch let error {
                    log.error("[Call] Failed to enable audio: \(error)", subsystems: .call)
                }
            }
            Task {
                do {
                    if call?.details.isVideo == true {
                        try await setVideoEnabled(true)
                    }
                } catch let error {
                    log.error("[Call] Failed to enable video: \(error)", subsystems: .call)
                }
            }
            if let call, call.details.isIncoming == false {
                log.debug("[WebRTC] Creating local data channel")
                localDataChannel = peerConnection.createDataChannel()
            }
            localDataChannel?.delegate = self
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

    /// Create `WebRTCClient` instance.
    ///
    /// - Parameters:
    ///    - factory: PeerConnectionFactory instance.
    ///    - signaling: Singaling instance.
    ///    - peerConnection: PeerConnection instance.
    ///    - audioManager: RTCAudioManager instance.
    /// - Returns: An instance of `WebRTCClient` object.
    init(factory: PeerConnectionFactory,
         signaling: SignalingProtocol,
         peerConnection: PeerConnection,
         audioManager: RTCAudioManager) {
        self.factory = factory
        self.signaling = signaling
        self.peerConnection = peerConnection
        self.audioManager = audioManager
        self.callIOState = CallIOState(isAudioEnabled: true,
                                       isVideoEnabled: false,
                                       isRemoteAudioEnabled: true,
                                       isRemoteVideoEnabled: false)
        super.init()
        peerConnection.delegate = self
        signaling.onReceiveCallSignal = { [weak self] callSignal in
            Task {
                do {
                    try await self?.handleSignalEvent(callSignal)
                } catch let error {
                    log.error("[ErmisCall] handle signal with error: \(error)")
                }
            }
        }
        self.setupMediaSenders()
        self.audioManager.updateAudioSessionConfigure()
    }

    /// Convinience way to create `WebRTCClient` instance.
    ///
    ///  - Parameters:
    ///     - singaling: `SingalingProtocol` instance.
    ///     - iceServers: List of `ICEServer`
    ///     - audioManager: `RTCAudioManager` instance.
    /// - Returns: An instance of `WebRTCClient` object.
    convenience
    public init(signaling: SignalingProtocol, iceServers: [ICEServer], audioManager: RTCAudioManager) {
        let factory = PeerConnectionFactory()
        let configuration = RTCConfiguration(with: iceServers)
        let peerConnection = try! factory.makePeerConnection(configuration: configuration,
                                                             delegate: nil)
        self.init(factory: factory,
                  signaling: signaling,
                  peerConnection: peerConnection,
                  audioManager: audioManager)
    }
    // MARK: - Setup
    private func setupMediaSenders() {
        let streamIds: [String] = ["ios_stream"]
        if localAudioTrack == nil {
            audioManager.setDefaultPort()
        }
        localAudioTrack = createAudioTrack()
        peerConnection.addTrack(localAudioTrack, streamIds: streamIds, trackType: .audio)
        //
        localVideoTrack = createVideoTrack()
        peerConnection.addTrack(localVideoTrack, streamIds: streamIds, trackType: .video)
        //
        remoteVideoTrack = peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver.track as? RTCVideoTrack
    }

    // MARK: - Action
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
                let sender = peerConnection.transceivers.first( where: { $0.sender.track is RTCVideoTrack})?.sender
                sender?.track = nil
                localVideoTrack?.isEnabled = false
                try await stopCapture()
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
                peerConnection.senders.first(where: { $0.senderId.contains("video") })?.track = localVideoTrack
                localVideoTrack?.isEnabled = true
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
            if !isEnable {
                let sender = peerConnection.transceivers.first( where: { $0.sender.track is RTCAudioTrack})?.sender
                sender?.track = nil
                localAudioTrack?.isEnabled = false
                callIOState.isAudioEnabled = false
            } else {
                let isMicrophoneAccessGranted = await ioAccessManager.requestMicrophoneAccessIfNeeded()
                guard isMicrophoneAccessGranted else {
                    setAudioEnable(false)
                    return
                }
                peerConnection.senders.first(where: { $0.senderId.contains("audio")})?.track = localAudioTrack
                localAudioTrack?.isEnabled = true
                callIOState.isAudioEnabled = true
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
        sendMessage(.transciverState(transciverState))
    }

    /// Send message via WebRTC data channel.
    ///
    /// - Parameters:
    ///    - message: The message to send.
    /// - Returns: A boolean value, `true` if message send success.
    func sendMessage(_ message: DataChannelMessage) -> Bool {
        guard remoteVideoTrack != nil else {
            log.warning("[WebRTC] data message ignored bacause: remote data channel nil", subsystems: .webRTC)
            return false
        }
        do {
            let data = try JSONEncoder().encode(message)
            let buffer = RTCDataBuffer(data: data, isBinary: true)
            if let localDataChannel {
                return localDataChannel.sendData(buffer)
            } else {
                return remoteDataChannel?.sendData(buffer) ?? false
            }
        } catch {
            log.error("[WebRTC] error when encoding message: \(message)", subsystems: .webRTC)
            return false
        }
    }
    // MARK: - Video
    /// Start capture video.
    ///
    /// - Parameters:
    ///    - device: The capture device.
    /// - Returns: Throws error if not successful.
    public
    func startCapture(device: AVCaptureDevice?) async throws {
        guard let videoCapturer = videoCapturer as? RTCCameraVideoCapturer else {
            throw ClientError.VideoCapturerInvalid()
        }

        guard let device,
              let format = (RTCCameraVideoCapturer.supportedFormats(for: device).sorted { (f1, f2) -> Bool in
                  let width1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
                  let width2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
                  return width1 < width2
              }).last(where: {
                  // use 1280 as max width demension.
                  CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1280
              }),

                // choose highest fps
              let fps = (format.videoSupportedFrameRateRanges.sorted { return $0.maxFrameRate < $1.maxFrameRate }.last) else {
            throw ClientError.Unexpected()
        }
        
        try await videoCapturer.startCapture(with: device, format: format, fps: min(Int(fps.maxFrameRate), 30))
    }

    /// Stop capture video.
    ///
    ///  - Returns: Throws error if not successful.
    public
    func stopCapture() async throws {
        if let videoCapturer = videoCapturer as? RTCCameraVideoCapturer {
            await videoCapturer.stopCapture()
        }
    }

    /// Set camera position and capture video.
    ///
    /// - Parameters:
    ///    - position: Position of camera want to use.
    /// - Returns: Throws error if not successful.
    public
    func setCameraPosition(_ position: CameraPosition) async throws {
        guard let device = RTCCameraVideoCapturer.captureDevice(for: position.captureDevicePosition) else {
            return
        }
        try await startCapture(device: device)
        callIOState.cameraPosition = position
    }

    /// Render local video to the renderer.
    ///
    /// - Parameters:
    ///    - renderer: The renderer to render local video track in.
    public
    func renderLocalVideo(to renderer: RTCVideoRenderer) {
        self.localVideoTrack?.add(renderer)
    }

    /// Render remote video to the renderer.
    ///
    /// - Parameters:
    ///    - renderer: The renderer to render remote video track in.
    public
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        if remoteVideoTrack == nil {
            remoteVideoTrack = peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver.track as? RTCVideoTrack
        }
        self.remoteVideoTrack?.add(renderer)
    }

    // MARK: - Signal
    /// Create a new call.
    ///
    /// - Parameters:
    ///    - isVideo: `true` if this call is video call.
    /// - Returns: Throws error if not successful.
    public func createCall(_ isVideo: Bool, sessionId: String) async throws {
        let callSignalPayload = try await signaling.sendSignal(sessionId: sessionId,
                                                               callId: nil,
                                                               action: .createCall,
                                                               isVideo: isVideo,
                                                               signalType: .none,
                                                               sdp: "")
        if call?.isLocalId == true {
            call?.setRemoteCallId(callSignalPayload.callId)
        }
    }

    /// Create and send offer signal to other.
    ///
    /// - Returns: Throws error if not successful.
    public func sendOffer() async throws {
        let sdp = try await peerConnection.createOffer(with: .default)
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .signalCall,
                                       isVideo: isVideoCall,
                                       signalType: .offer, sdp: sdp.sdp)
        log.debug("[WebRTC] Send offer callID: \(call?.details.callId ?? "")")
    }

    /// Create and send answer signal to other.
    ///
    /// - Returns: Throws error if not successful.
    public func sendAnswer() async throws {
        let sdp = try await peerConnection.createAnswer(with: .default)
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .signalCall,
                                       isVideo: isVideoCall,
                                       signalType: .answer,
                                       sdp: sdp.sdp)
        log.debug("[WebRTC] Send answer callID: \(call?.details.callId ?? "")")
    }

    /// Sending all current pending ices to other.
    ///
    /// - Returns: Throws error if not successful.
    public func sendPendingIces() async throws {
        for ice in pendingLocalICE {
            try await signaling.sendSignal(sessionId: sessionId,
                                           callId: call?.details.callId,
                                           action: .signalCall,
                                           isVideo: isVideoCall,
                                           signalType: .ice,
                                           sdp: ice.sdpString)
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
                                       sdp: nil)
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
                                       sdp: nil)
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
                                       sdp: nil)
    }

    /// Send accept call signal.
    ///
    /// - Returns: Throws error if not successful.
    public func acceptCall() async throws {
        try await signaling.sendSignal(sessionId: sessionId,
                                       callId: call?.details.callId,
                                       action: .acceptCall,
                                       isVideo: isVideoCall,
                                       signalType: nil,
                                       sdp: nil)
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
                                       sdp: nil)
        peerConnection.close()
    }

    /// Stop current call and send endcall signal.
    ///
    /// - Returns: Throws error if not successful.
    public func endCall() async throws {
        defer {
            peerConnection.close()
        }
        setAudioEnable(false)
        setVideoEnabled(false)
        if call?.details.isIncoming == false {
            try audioManager.deactiveAudioSession()
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
                                           sdp: nil)
        } else {
            try await signaling.sendSignal(sessionId: sessionId,
                                           callId: call?.details.callId,
                                           action: .endCall,
                                           isVideo: isVideoCall,
                                           signalType: nil,
                                           sdp: nil)
        }
    }

    /// Stop IO and close peerconnection.
    /// - Note: This will not send end call signal to other device
    func close() {
        setAudioEnable(false)
        setVideoEnabled(false)
        if call?.details.isIncoming == false {
            try? audioManager.deactiveAudioSession()
        }
        peerConnection.close()
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
            break
        case .acceptCall:
            call?.setState(.connecting)
            try await sendOffer()
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
            guard call?.details.state == .connecting else {
                return
            }
            call?.setState(.connected)
        case .healthCall:
            break
        case .endCall:
            call?.setState(.ended)
            Task {
                try? await endCall()
            }
        case .signalCall:
            guard let signal = callSignal.signal else {
                log.warning("[WebRTC] Receive invalid call signal: \(callSignal.callAction)")
                return
            }
            guard call?.details.state != .idle, call?.details.state != .ringing else {
                close()
                return
            }
            switch signal.type {
            case .ice:
                guard call?.details.state == .connecting || call?.details.state == .connected else {
                    return
                }
                if let ice = ICECandidate(from: signal.sdp) {
                    try await peerConnection.add(iceCandidate: ice.rtcICE)
                }
            case .answer:
                guard call?.details.state == .connecting else {
                    return
                }
                try await peerConnection.setRemoteSDP(sdp: signal.sdp, type: .answer)
                isReadyToSendICE = true
                try await sendPendingIces()
            case .offer:
                guard call?.details.state == .connecting else {
                    return
                }
                try await peerConnection.setRemoteSDP(sdp: signal.sdp, type: .offer)
                try await sendAnswer()
                isReadyToSendICE = true
                try await sendPendingIces()
            default:
                break
            }
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
        case .transciverState(let transciverState):
            callIOState.isRemoteAudioEnable = transciverState.audioEnable
            callIOState.isRemoteVideoEnabled = transciverState.videoEnable
            callIOStatePublisher.send(callIOState)
        case .endCall:
            call?.setState(.ended)
            Task {
                await  CallManager.shared.endCall(call)
            }
            Task {
                try? await endCall()
            }
            break
        case .healthCall:
            delegate?.webRTCClientDidReciveHealthCallMessage(self)
        }
    }

    // MARK: - Helper
    private func createAudioTrack() -> RTCAudioTrack {
        let contraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.createAudioSource(with: contraints)
        let audioTrack = factory.createAudioTrack(with: audioSource)
        return audioTrack
    }

    private func createVideoTrack() -> RTCVideoTrack {
        let contraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let videoSource = factory.createVideoSource(for: false)
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        let videoTrack = factory.createVideoTrack(with: videoSource)
        return videoTrack
    }
}

// MARK: - PeerConnectionDelegate
extension WebRTCClient: PeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_ peerConnection: PeerConnection) {

    }

    func peerConnection(_ peerConnection: PeerConnection, didChange connectionState: RTCPeerConnectionState) {
        if connectionState == .connected {
            Task {
                // Send connected signal
                if call?.details.state == .connecting, call?.details.isIncoming == false {
                    do {
                        try await sendConnectedCallSignal()
                        call?.setState(.connected)
                    } catch let error {
                        log.error("[Call] failed to sent connect signal: \(error)", subsystems: .call)
                        await CallManager.shared.endCall(call)
                        return
                    }
                } else {
                    call?.setState(.connected)
                }
            }
        }
    }

    func peerConnection(_ peerConnection: PeerConnection, didAddStream stream: RTCMediaStream) {
        remoteVideoTrackPublisher.send(peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver.track as? RTCVideoTrack)
    }

    func peerConnection(_ peerConnection: PeerConnection, didRemoveStream stream: RTCMediaStream) {
        remoteVideoTrackPublisher.send(peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver.track as? RTCVideoTrack)
    }

    func peerConnection(_ peerConnection: PeerConnection, didGenerate candidate: ICECandidate) {
        if isReadyToSendICE {
            Task {
                try? await self.signaling.sendSignal(sessionId: sessionId,
                                                     callId: call?.details.callId,
                                                     action: .signalCall,
                                                     isVideo: isVideoCall,
                                                     signalType: .ice,
                                                     sdp: candidate.sdpString)
            }
        } else {
            pendingLocalICE.append(candidate)
        }
    }

    func peerConnection(_ peerConnection: PeerConnection, didOpen dataChannel: RTCDataChannel) {
        log.debug("[WebRTC] data channel: \(dataChannel.label) did open")
        remoteDataChannel = dataChannel
        remoteDataChannel?.delegate = self
        sendTrascriptionStateMessage()
    }
}
// MARK: - RTCDataChannelDelegate
extension WebRTCClient: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log.debug("[WebRTC] data channel: \(dataChannel.label) did changed state: \(dataChannel.readyState)", subsystems: .webRTC)
        sendTrascriptionStateMessage()
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        do {
            let message = try jsonDecoder.decode(DataChannelMessage.self, from: buffer.data)
            log.debug("[WebRTC] data channel: \(dataChannel.label) did receive message: \(message)")
            handleDataChannelMessage(message)
        } catch let error {
            log.error("[WebRTC] failed to decode data channel message: \(error.localizedDescription)", subsystems: .webRTC)
        }
    }
}
