//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import AVFAudio
import Combine
import UIKit

// Represent a call.
public actor Call {
    /// The session identifier of call. This use to detect current device of user.
    public let sessionId: String
    /// The ermis chat client instance.
    public let client: ErmisClient
    /// The webrtc client instance.
    public nonisolated let callNodeClient: CallNodeClient
    
    // Private actor-isolated storage
    public var details: CallDetails

    /// The publisher that publish the state value of the call.
    public nonisolated let callStatePublisher = CurrentValueSubject<CallState, Never>(.idle)
    /// The publisher that publish the call duration time.
    public nonisolated let durationTimerPublisher = CurrentValueSubject<TimeInterval, Never>(0)
    /// The publisher that publish the connection status.
    public nonisolated let connectionStatusPublisher = CurrentValueSubject<CallConnectionStatus, Never>(.normal)

    public nonisolated var audioManager: ErmisCallAudioManager {
        return ErmisCallAudioManager.shared
    }

    public var remoteVideoView: Any?

    public nonisolated let renderView = VideoRenderView()
    
    // Timer management - kept on MainActor for proper Timer operation
    private var timeoutTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    
    /// Call connection time value.
    private var duration: TimeInterval = 0

    public var isLocalId: Bool {
        return details.uuid.uuidString == details.callId
    }

    public var callId: String {
        return details.callId
    }

    public var uuid: UUID {
        return details.uuid
    }

    public var cid: ChannelId {
        return details.cid
    }

    public var isMissed: Bool = false

    @MainActor
    init(sessionId: String, client: ErmisClient, callNodeClient: CallNodeClient, callDetails: CallDetails) {
        log.debug("[Call] INIT: \(callDetails.callId), uuid: \(callDetails.uuid)", subsystems: .call)
        self.sessionId = sessionId
        self.client = client
        self.callNodeClient = callNodeClient
        self.details = callDetails
        
        // Set up callNodeClient relationships - note: delegate/call setup is done in convenience init
        renderView.attach(with: callNodeClient.player)
        renderView.backgroundColor = .clear
        renderView.translatesAutoresizingMaskIntoConstraints = false

        callNodeClient.sessionId = sessionId
        callNodeClient.currentUserId = details.currentUser?.userId
        

    }

    @MainActor
    convenience init?(sessionId: String, uuid: UUID, callId: String, cid: ChannelId, client: ErmisClient, isVideo: Bool, isIncoming: Bool) {
        let channelController = client.channelController(for: cid)
        guard let channel = channelController.channel else {
            log.debug("[Call] Failed to init because can not get channel for cid: \(cid)")
            return nil
        }
        self.init(sessionId: sessionId,
                  uuid: uuid,
                  callId: callId,
                  channel: channel,
                  client: client,
                  isVideo: isVideo,
                  isIncoming: isIncoming)
    }

    @MainActor
    convenience init?(sessionId: String, uuid: UUID, callId: String, channel: Channel, client: ErmisClient, isVideo: Bool, isIncoming: Bool) {
        let audioManager = ErmisCallAudioManager.shared
        let signaling = Signaler(client: client, cid: channel.cid)
        let relayUrls = ["https://iroh-relay.ermis.network:8443"]
        guard let callNodeClient = CallNodeClient(signaling: signaling, relayUrls: relayUrls) else {
            return nil
        }

        let callDetails = CallDetails(uuid: uuid,
                                      callId: callId,
                                      cid: channel.cid,
                                      title: channel.directUserMembership?.displayName ?? channel.name ?? channel.cid.rawValue,
                                      imageURL: channel.directUserMembership?.imageURL ?? channel.imageURL,
                                      isVideo: isVideo,
                                      isIncoming: isIncoming,
                                      currentUser: channel.membership)

        self.init(sessionId: sessionId,
                  client: client,
                  callNodeClient: callNodeClient,
                  callDetails: callDetails)
        
        // Set up the delegate and call reference
        callNodeClient.call = self
        
        Task {
            await self.startTimeoutTimer()
        }
    }

    deinit {
        log.debug("[Call] DEINIT: \(details.callId), uuid: \(details.uuid)", subsystems: .call)
        timeoutTask?.cancel()
        durationTask?.cancel()
    }

    // MARK: - Life cycle

    public func createCall() async throws {
        log.debug("[Call] createCall() START - callId: \(details.callId)", subsystems: .call)
        try await callNodeClient.createCall(details.isVideo, sessionId: sessionId)
    }

    public func acceptCall() async throws {
        log.debug("[Call] acceptCall() START - callId: \(details.callId)", subsystems: .call)
        try await callNodeClient.acceptCall()
        setState(.connecting)
    }

    public func rejectCall() async throws {
        log.debug("[Call] rejectCall() START - callId: \(details.callId)", subsystems: .call)
        try await callNodeClient.rejectCall()
        log.debug("[Call] rejectCall() - callNodeClient.rejectCall() completed", subsystems: .call)
        setState(.ended)
        log.debug("[Call] rejectCall() END - state set to .ended", subsystems: .call)
    }

    public func endCall() async throws {
        log.debug("[Call] endCall() START - callId: \(details.callId), state: \(details.state)", subsystems: .call)
        try await callNodeClient.endCall()
        log.debug("[Call] endCall() - callNodeClient.endCall() completed", subsystems: .call)
        setState(.ended)
        log.debug("[Call] endCall() END - state set to .ended", subsystems: .call)
    }

    public func close() {
        log.debug("[Call] close() START - callId: \(details.callId)", subsystems: .call)
        callNodeClient.close()
        setState(.ended)
    }

    public func setRemoteCallId(_ callId: String) async {
        details.callId = callId
        await CallManager.shared.addToCallUUIDDictionary(callId: callId, uuid: self.details.uuid)
    }
    /// Set new state for current call.
    ///
    ///  - Parameters:
    ///    - callState: The new state of current call.
    public func setState(_ callState: CallState) {
        log.debug("[Call] setState called: \(callState) for \(self.details.callId)", subsystems: .call)
        
        log.debug("[Call] Set state: \(callState)")
        self.details.state = callState
        self.callStatePublisher.send(callState)
        
        switch callState {
        case .ringing:
            break
        case .connecting:
            if self.details.isIncoming {
                Task(priority: .medium) { [weak self] in
                    guard let self else {
                        return
                    }
                    do {
                        try await self.callNodeClient.connectToRemote()
                    } catch {
                        log.error("[Call] Failed to connect to remote node, error: \(error)")
                        let callId = await self.details.callId
                        CallManager.shared.endCall(with: callId)
                    }
                }
            }
        case .connected:
            if !self.details.isIncoming {
                Task { @MainActor in
                    CallManager.shared.reportOutgoingCallConnected(uuid: await self.details.uuid, connectedAt: Date())
                }
                CallManager.shared.stopPlayingRingingSound()
            }
            self.stopTimeoutTimer()
            self.startDurationTimer()
            log.debug("[Call] State transitioned to .connected for \(self.details.callId)", subsystems: .call)
        case .ended:
            CallManager.shared.stopPlayingRingingSound()
            self.stopTimeoutTimer()
            self.stopDurationTimer()
            log.debug("[Call] State transitioned to .ended for \(self.details.callId)", subsystems: .call)
        default:
            break
        }
    }

    public func setIsVideo(_ isVideo: Bool) {
        log.debug("TTTTTT SET IS VIDEO: \(isVideo)", subsystems: .call)
        details.isVideo = isVideo
        callStatePublisher.send(callStatePublisher.value)
    }

    @MainActor
    public func didActiveAudioSession() async {
        log.debug("[Call] did active audio session.", subsystems: .call)
        audioManager.didActivateAudioSession()
        await callNodeClient.didActiveAudioSession()
//        callNodeClient.didActiveAudioSession()
//        audioManager.didActivateAudioSession()
    }

    public func didDeactiveAudioSession() {
        callNodeClient.didDeactiveAudioSession()
    }
    
    // MARK: - Control
    /// Set new audio port
    ///
    ///  - Parameters:
    ///     - port: The audio session port value to set.
    public nonisolated func setAudioPort(_ port: AVAudioSession.Port) {
        audioManager.changeAudioPort(to: port)
    }
    
    /// Toggle mute state, if current mic is mute, it will unmute and otherwise.
    public func toggleMute() async {
        await callNodeClient.toggleAudio()
    }

    /// Set mic mute state
    ///
    ///  - Parameters:
    ///   - isMute: The boolean value for mic mute state. if `true` mic will be muted and otherwise.
    public func setMute(_ isMute: Bool) async {
        await callNodeClient.setAudioEnable(!isMute)
    }

    /// Toggle video enable state.
    public func toggleVideo() async {
        await callNodeClient.toggleVideo()
    }

    /// Set video enable state
    ///
    ///  - Parameters:
    ///   - isEnabled: The boolean value for video enable state. if `true` video will be enabled and otherwise.
    public func setVideoEnabled(_ isEnabled: Bool) {
        Task { @MainActor in
            await callNodeClient.setVideoEnabled(isEnabled)
        }
    }

    /// Toggle camera position.
    public func toggleCameraPosition() async {
        do {
            try await callNodeClient.toggleCameraPosition()
        } catch let error {
            log.error("[WebRTC] Error when changing camera position: \(error)")
        }
    }

    /// Set camera postion, throw error if failure.
    ///
    ///  - Parameters:
    ///   - position: New camera position want to set.
    public func setCameraPosition(_ position: CameraPosition) {
        do {
            try callNodeClient.setCameraPosition(position)
        } catch let error {
            log.error("[WebRTC] Error when changing camera position: \(error)")
        }
    }

    public func isCallWithId(_ callId: String) -> Bool {
        return details.callId == callId || details.uuid.uuidString == callId
    }
}
// MARK: - Timer
extension Call {
    func startTimeoutTimer() {
        log.debug("[Call] Scheduling timeout timer for callId: \(details.callId)", subsystems: .call)
        
        // Cancel any existing timeout task
        timeoutTask?.cancel()
        
        // Create a new task that acts as our timer
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                
                guard !Task.isCancelled else { return }
                
                await self.handleTimeout()
            } catch {
                // Task was cancelled or interrupted
            }
        }
    }
    
    func stopTimeoutTimer() {
        log.debug("[Call] Cancelling timeout timer for callId: \(details.callId)", subsystems: .call)
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func handleTimeout() async {
        log.debug("[Call] Timeout timer fired for callId: \(details.callId)", subsystems: .call)
        switch details.state {
        case .idle, .ringing, .connecting:
            if !details.isIncoming {
                isMissed = true
                log.debug("[Call] Time out for connecting call, ending call")
                CallManager.shared.endCall(with: self.details.callId)
            }
        default:
            break
        }
    }

    private func startDurationTimer() {
        log.debug("[Call] Starting duration timer for callId: \(details.callId)", subsystems: .call)
        stopDurationTimer()
        
        // Create a task that ticks every second
        durationTask = Task { [weak self] in
            guard let self else { return }
            
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    
                    guard !Task.isCancelled else { return }
                    
                    await self.handleDurationTick()
                } catch {
                    // Task was cancelled or interrupted
                    break
                }
            }
        }
    }

    private func stopDurationTimer() {
        log.debug("[Call] Stopping duration timer for callId: \(details.callId)", subsystems: .call)
        durationTask?.cancel()
        durationTask = nil
        duration = 0
    }

    private func handleDurationTick() async {
        duration += 1
        log.debug("[Call] Duration timer tick for callId: \(details.callId), duration: \(duration)", subsystems: .call)
        durationTimerPublisher.send(duration)

        if !callNodeClient.isCallNodeConnected() {
            connectionStatusPublisher.send(.yourConnectionIsBeingEstablished)
            
            // Schedule end call after 6 seconds of no connection
            Task.detached {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !self.callNodeClient.isCallNodeConnected() {
                    let callId = await self.details.callId
                    CallManager.shared.endCall(with: callId)
                    await self.stopDurationTimer()
                }
            }
            return
        }

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

// MARK: - Equatable
extension Call {
    public static func == (lhs: Call, rhs: Call) async -> Bool {
        await lhs.details.callId == rhs.details.callId
    }
    
    public nonisolated func isEqual(to other: Call) -> Bool {
        // For synchronous equality checks where we can't use await
        // This is a limitation of actor conversion
        return ObjectIdentifier(self) == ObjectIdentifier(other)
    }
}

