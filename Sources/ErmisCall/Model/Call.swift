//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import AVFAudio
import Combine

// Represent a call.

public class Call: NSObject {
    /// The session identifier of call. This use to detect current device of user.
    public let sessionId: String
    /// The ermis chat client instance.
    public let client: ErmisClient
    /// The webrtc client instance.
    public let webRTCClient: WebRTCClient
    /// The audio manager 
    public let audioManager: RTCAudioManager
    /// The details infomation of the call.
    public var details: CallDetails {
        didSet {
            if details.state != oldValue.state {
                callStatePublisher.send(details.state)
                if details.state == .connected {
                    stopTimeoutTimer()
                    startDurationTimer()
                } else if details.state == .ended {
                    stopTimeoutTimer()
                    stopDurationTimer()
                }
            }
        }
    }

    /// The publisher that publish the state value of the call.
    public private(set) var callStatePublisher = CurrentValueSubject<CallState, Never>(.idle)
    /// The publisher that publish the call duration time.
    public private(set) var durationTimerPublisher = CurrentValueSubject<TimeInterval, Never>(0)
    /// The publisher that publish the connection status.
    public private(set) var connectionStatusPublisher = CurrentValueSubject<CallConnectionStatus, Never>(.normal)

    /// Timer for timeout when connecting call. If call not connected after timeout, the call will be ended automatically.
    var timeoutTimer: Timer?
    /// Timer for call connection time.
    private var durationTimer: Timer?
    /// Call connection time value.
    private var duration: TimeInterval = 0

    /// Last time receive health call message from other, if this longer than max waiting time, the call will be ended.
    private var lastTimeReceivedHealthCallMessage: Date?

    var isLocalId: Bool {
        return details.uuid.uuidString == details.callId
    }

    var isMissed: Bool = false

    private let connectionController: ConnectionController

    init(sessionId: String, client: ErmisClient, webRTCClient: WebRTCClient, audioManager: RTCAudioManager, callDetails: CallDetails) {
        self.sessionId = sessionId
        self.client = client
        self.webRTCClient = webRTCClient
        self.audioManager = audioManager
        self.details = callDetails
        self.connectionController = client.connectionController()
        super.init()
        webRTCClient.delegate = self
        webRTCClient.call = self
    }

    convenience init(sessionId: String, uuid: UUID, callId: String, cid: ChannelId, client: ErmisClient, isVideo: Bool, isIncoming: Bool) {
        let channelController = client.channelController(for: cid)
        guard let channel = channelController.channel else {
            fatalError("Channel not found")
        }

        let iceServer = ICEServer(userName: "", password: "", urls: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
            "stun:stun2.l.google.com:19302",
            "stun:stun3.l.google.com:19302",
            "stun:stun4.l.google.com:19302"
        ])

        let turnIceServer = ICEServer(userName: "hoang", password: "pass1", urls: [
            "turn:36.50.63.8:3478"
        ])
        
        let audioManager = RTCAudioManager()
        let signaling = Signaler(client: channelController.client, cid: channel.cid)
        let webRTCClient = WebRTCClient(signaling: signaling,
                                        iceServers: [turnIceServer],
                                        audioManager: audioManager)


        let callDetails = CallDetails(uuid: uuid,
                                      callId: callId,
                                      cid: channel.cid,
                                      title: channel.directUserMembership?.name ?? channel.name ?? channel.cid.rawValue,
                                      imageURL: channel.directUserMembership?.imageURL ?? channel.imageURL,
                                      isVideo: isVideo,
                                      isIncoming: isIncoming,
                                      currentUser: channel.membership)

        self.init(sessionId: sessionId,
                  client: client,
                  webRTCClient: webRTCClient,
                  audioManager: audioManager,
                  callDetails: callDetails)
        startTimeoutTimer()

        audioManager.setUseManualAudio(isIncoming)
    }

    public override var description: String {
        return "Call \(details)"
    }

    // MARK: - Life cycle
    func connectionSocket() async throws {
        guard client.connectionStatus != .connected else {
            return
        }
        return try await withCheckedThrowingContinuation { continuation in
            connectionController.connect(completion: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func createCall() async throws {
        try await webRTCClient.createCall(details.isVideo, sessionId: sessionId)
        details.state = .ringing
    }

    func acceptCall() async throws {
        try await webRTCClient.acceptCall()
        setState(.connecting)
    }

    func rejectCall() async throws {
        log.debug("[Call] Reject call with id: \(details.callId)")
        try await webRTCClient.rejectCall()
        setState(.ended)
    }

    func endCall() async throws {
        try await webRTCClient.endCall()
        setState(.ended)
    }

    func close() async throws {
        try await webRTCClient.close()
        setState(.ended)
    }

    func setRemoteCallId(_ callId: String) {
        details.callId = callId
        CallManager.shared.addCall(self)
    }
    /// Set new state for current call.
    ///
    ///  - Parameters:
    ///    - callState: The new state of current call.

    public func setState(_ callState: CallState) {
        self.details.state = callState
        callStatePublisher.send(callState)
        switch callState {
        case .ringing:
            CallManager.shared.playRingingSoundIfNeeded()
        case .connected:
            if !details.isIncoming {
                CallManager.shared.reportOutgoingCallConnected(uuid: details.uuid, connectedAt: Date())
                CallManager.shared.stopPlayingRingingSound()
            }
        case .ended:
            CallManager.shared.stopPlayingRingingSound()
        default:
            break
        }
    }
    // MARK: - Control
    /// Set new audio port
    ///
    ///  - Parameters:
    ///     - port: The audio session port value to set.
    func setAudioPort(_ port: AVAudioSession.Port) {
        audioManager.changeAudioPort(to: port)
    }
    /// Toggle mute state, if current mic is mute, it will unmute and otherwise.
    func toggleMute() {
        webRTCClient.toggleAudio()
    }

    /// Set mic mute state
    ///
    ///  - Parameters:
    ///   - isMute: The boolean value for mic mute state. if `true` mic will be muted and otherwise.
    func setMute(_ isMute: Bool) {
        webRTCClient.setAudioEnable(!isMute)
    }

    /// Toggle video enable state.
    func toggleVideo() {
        webRTCClient.toggleVideo()
    }

    /// Set video enable state
    ///
    ///  - Parameters:
    ///   - isEnabled: The boolean value for video enable state. if `true` video will be enabled and otherwise.
    func setVideoEnabled(_ isEnabled: Bool) {
        webRTCClient.setVideoEnabled(isEnabled)
    }

    /// Toggle camera position.
    func toggleCameraPosition() {
        Task {
            do {
                try await webRTCClient.toggleCameraPosition()
            } catch let error {
                log.error("[WebRTC] Error when changing camera position: \(error)")
            }
        }
    }

    /// Set camera postion, throw error if failure.
    ///
    ///  - Parameters:
    ///   - position: New camera position want to set.
    func setCameraPosition(_ position: CameraPosition) {
        Task {
            do {
                try await webRTCClient.setCameraPosition(position)
            } catch let error {
                log.error("[WebRTC] Error when changing camera position: \(error)")
            }
        }
    }
}
// MARK: - Timer
extension Call {
    func startTimeoutTimer() {
        timeoutTimer?.invalidate()
        DispatchQueue.main.async {
            self.timeoutTimer = Timer.scheduledTimer(timeInterval: 60,
                                              target: self,
                                              selector: #selector(self.timerDidFire),
                                              userInfo: nil, repeats: false)
        }
    }
    
    func stopTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    @objc func timerDidFire() {
        switch details.state {
        case .idle, .ringing, .connecting:
            Task {
                isMissed = true
                try await CallManager.shared.endCall(self)
            }
        default:
            break
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        DispatchQueue.main.async {
            self.durationTimer = Timer.scheduledTimer(timeInterval: 1,
                                                      target: self,
                                                      selector: #selector(self.durationTimerDidFire),
                                                      userInfo: nil,
                                                      repeats: true)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        duration = 0
        durationTimerPublisher.send(duration)
    }

    @objc private func durationTimerDidFire() {
        duration += 1
        durationTimerPublisher.send(duration)

        if lastTimeReceivedHealthCallMessage == nil {
            lastTimeReceivedHealthCallMessage = Date()
        }

        webRTCClient.sendMessage(.healthCall)
        if let durationNotReceivedHealthCallMessage = lastTimeReceivedHealthCallMessage?.timeIntervalSinceNow {
            if durationNotReceivedHealthCallMessage < -30 {
                Task {
                    await CallManager.shared.endCall(self)
                }
                stopDurationTimer()
                return
            } else if durationNotReceivedHealthCallMessage < -6 {
                let isConnected = client.connectionStatus == .connected
                connectionStatusPublisher.send(isConnected ? .theirConnectionIsBeingEstablished(userIds: []) : .yourConnectionIsBeingEstablished)
            } else if durationNotReceivedHealthCallMessage < -3 {
                connectionStatusPublisher.send(.lowConnection)
            } else {
                connectionStatusPublisher.send(.normal)
            }
        }




        if Int(duration) % 10 == 0 {
            Task {
                do {
                    try await webRTCClient.sendHealthCallSignal()
                } catch let error {
                    log.error("[Call] Error when send health call signal: \(error)")
                }
            }
        }
    }
}
// MARK: - WebRTCClientDelegate
extension Call: WebRTCClientDelegate {
    func webRTCClientDidReciveHealthCallMessage(_ webRTCClient: WebRTCClient) {
        lastTimeReceivedHealthCallMessage = Date()
    }
}
// MARK: - Equatable
extension Call {
    static func == (lhs: Call, rhs: Call) -> Bool {
        lhs.details.callId == rhs.details.callId
    }
}
