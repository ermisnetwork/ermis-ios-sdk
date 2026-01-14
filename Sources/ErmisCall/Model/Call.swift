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
    public let callNodeClient: CallNodeClient
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

    public var audioManager: ErmisCallAudioManager {
        return ErmisCallAudioManager.shared
    }
    /// Timer for timeout when connecting call. If call not connected after timeout, the call will be ended automatically.
    var timeoutTimer: Timer?
    /// Timer for call connection time.
    private var durationTimer: Timer?
    /// Call connection time value.
    private var duration: TimeInterval = 0

//    /// Last time receive health call message from other, if this longer than max waiting time, the call will be ended.
//    private var lastTimeReceivedHealthCallMessage: Date?

    var isLocalId: Bool {
        return details.uuid.uuidString == details.callId
    }

    var isMissed: Bool = false

    public var isAccected: Bool = false

    init(sessionId: String, client: ErmisClient, callNodeClient: CallNodeClient, callDetails: CallDetails) {
        self.sessionId = sessionId
        self.client = client
        self.callNodeClient = callNodeClient
        self.details = callDetails
        super.init()
        callNodeClient.delegate = self
        callNodeClient.call = self
    }

    convenience init?(sessionId: String, uuid: UUID, callId: String, cid: ChannelId, client: ErmisClient, isVideo: Bool, isIncoming: Bool) {
        let channelController = client.channelController(for: cid)
        guard let channel = channelController.channel else {
            return nil
        }
        
        let audioManager = ErmisCallAudioManager.shared
        let signaling = Signaler(client: channelController.client, cid: channel.cid)
        let relayUrls = ["https://iroh-relay.ermis.network:8443"]
        guard let callNodeClient = CallNodeClient(signaling: signaling, relayUrls: relayUrls) else {
            return nil
        }


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
                  callNodeClient: callNodeClient,
                  callDetails: callDetails)
        startTimeoutTimer()

//        audioManager.setUseManualAudio(isIncoming)
    }

    deinit {
        log.debug("TTTT CALL DEINIT")
    }

    public override var description: String {
        return "Call \(details)"
    }

    // MARK: - Life cycle

    func createCall() async throws {
        log.debug("TTTT CREATE CALL")
        try await callNodeClient.createCall(details.isVideo, sessionId: sessionId)
    }

    func acceptCall() async throws {
        try await callNodeClient.acceptCall()
        setState(.connecting)
    }

    func rejectCall() async throws {
        log.debug("[Call] Reject call with id: \(details.callId)")
        try await callNodeClient.rejectCall()
        setState(.ended)
    }

    func endCall() async throws {
        try await callNodeClient.endCall()
        setState(.ended)
    }

    func close() throws {
        try  callNodeClient.close()
        setState(.ended)
    }

    func setRemoteCallId(_ callId: String) {
        details.callId = callId
        CallManager.shared.callUUIDDictionary[callId] = details.uuid
    }
    /// Set new state for current call.
    ///
    ///  - Parameters:
    ///    - callState: The new state of current call.

    public func setState(_ callState: CallState) {
        let setStateBlock = {
            log.debug("[Call] Set state: \(callState)")
            self.details.state = callState
            self.callStatePublisher.send(callState)
            switch callState {
            case .ringing:
                break
            case .connecting:
                if self.details.isIncoming {
                    Task(priority: .high) { [weak self] in
                        guard let self else {
                            return
                        }
                        do {
                            try await self.callNodeClient.connectToRemote()
                        } catch {
                            log.error("[Call] Failed to connect to remote node, error: \(error)")
                            CallManager.shared.endCall(with: self.details.callId)
                        }
                    }
                }
            case .connected:
                if !self.details.isIncoming {
                    CallManager.shared.reportOutgoingCallConnected(uuid: self.details.uuid, connectedAt: Date())
                    CallManager.shared.stopPlayingRingingSound()
                }
            case .ended:
                CallManager.shared.stopPlayingRingingSound()
            default:
                break
            }
        }

        if Thread.isMainThread {
            setStateBlock()
        } else {
            DispatchQueue.main.async {
                setStateBlock()
            }
        }
    }

    public func didActiveAudioSession() {
        callNodeClient.didActiveAudioSession()
    }

    public func didDeactiveAudioSession() {
        callNodeClient.didDeactiveAudioSession()
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
        callNodeClient.toggleAudio()
    }

    /// Set mic mute state
    ///
    ///  - Parameters:
    ///   - isMute: The boolean value for mic mute state. if `true` mic will be muted and otherwise.
    func setMute(_ isMute: Bool) {
        callNodeClient.setAudioEnable(!isMute)
    }

    /// Toggle video enable state.
    func toggleVideo() {
        callNodeClient.toggleVideo()
    }

    /// Set video enable state
    ///
    ///  - Parameters:
    ///   - isEnabled: The boolean value for video enable state. if `true` video will be enabled and otherwise.
    func setVideoEnabled(_ isEnabled: Bool) {
        callNodeClient.setVideoEnabled(isEnabled)
    }

    /// Toggle camera position.
    func toggleCameraPosition() {
        do {
            try callNodeClient.toggleCameraPosition()
        } catch let error {
            log.error("[WebRTC] Error when changing camera position: \(error)")
        }
    }

    /// Set camera postion, throw error if failure.
    ///
    ///  - Parameters:
    ///   - position: New camera position want to set.
    func setCameraPosition(_ position: CameraPosition) {
        Task(priority: .userInitiated) {
            do {
                try await callNodeClient.setCameraPosition(position)
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
            if !details.isIncoming {
                isMissed = true
                try CallManager.shared.endCall(with: self.details.callId)
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

//        if lastTimeReceivedHealthCallMessage == nil {
//            lastTimeReceivedHealthCallMessage = Date()
//        }

        if !callNodeClient.isCallNodeConnected() {
            connectionStatusPublisher.send(.yourConnectionIsBeingEstablished)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: {
                CallManager.shared.endCall(with: self.details.callId)
                self.stopDurationTimer()
            })
            return
        }

//        if callNodeClient.isCallNodeConnected() {
//            lastTimeReceivedHealthCallMessage = Date()
//            connectionStatusPublisher.send(.yourConnectionIsBeingEstablished)
//            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: {
//                Task(priority: .high) {
//                    await CallManager.shared.endCall(self)
//                }
//                self.stopDurationTimer()
//            })
//            return
//        }
//
//        if let durationNotReceivedHealthCallMessage = lastTimeReceivedHealthCallMessage?.timeIntervalSinceNow {
//            if durationNotReceivedHealthCallMessage < -30 {
//                Task(priority: .high) {
//                    await CallManager.shared.endCall(self)
//                }
//                stopDurationTimer()
//                return
//            } else if durationNotReceivedHealthCallMessage < -6 {
//                let isConnected = client.connectionStatus == .connected
//                connectionStatusPublisher.send(isConnected ? .theirConnectionIsBeingEstablished(userIds: []) : .yourConnectionIsBeingEstablished)
//            } else if durationNotReceivedHealthCallMessage < -3 {
//                connectionStatusPublisher.send(.lowConnection)
//            } else {
//                connectionStatusPublisher.send(.normal)
//            }
//        }

        if Int(duration) % 10 == 0 {
            Task {
                do {
                    try await callNodeClient.sendHealthCallSignal()
                } catch let error {
                    log.error("[Call] Error when send health call signal: \(error)")
                }
            }
        }
    }
}
// MARK: - WebRTCClientDelegate
extension Call: WebRTCClientDelegate {

}
// MARK: - Equatable
extension Call {
    static func == (lhs: Call, rhs: Call) -> Bool {
        lhs.details.callId == rhs.details.callId
    }
}

