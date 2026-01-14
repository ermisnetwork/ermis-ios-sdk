//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit
import Combine
import AVFAudio
import ErmisCallNode

public
protocol CallControllerDelegate: AnyObject {
    func callStateDidChange(to callState: CallState)
    func callConnectionStatusDidChange(to connectionStatus: CallConnectionStatus)
    func callIOStateDidChange(to callIOState: CallIOState)
    func durationDidChange(to duration: TimeInterval)
    func audioPortChange(to port: AudioPort?)
    func startEndingCall(_ notification: Notification)
    func callDidEnd(_ notification: Notification)
    func callDidUpdateConnectionStats(status: ConnectionStats)
    func remoteVideoOrientationDidChanged(to orientation: VideoOrientation)
}

public
class CallController: NSObject {
    public let channel: Channel
    public weak var call: Call?

    public weak var delegate: CallControllerDelegate?

    private var cancelBags: Set<AnyCancellable> = []

    public var callNodeClient: CallNodeClient? {
        return call?.callNodeClient
    }


    public init(with channel: Channel, call: Call) {
        self.channel = channel
        self.call = call
    }

    deinit {
        log.debug("TTTT CALL CONTROLLER DEINIT")
    }
    // MARK: - Observer
    /// Start observer call. You can handle all changes via `CallControllerDelegate`.
    package func startCallObservers() {
        call?.callStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] callState in
                self?.delegate?.callStateDidChange(to: callState)
            }
            .store(in: &cancelBags)

        call?.connectionStatusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionStatus in
                self?.delegate?.callConnectionStatusDidChange(to: connectionStatus)
            }
            .store(in: &cancelBags)

        callNodeClient?.callIOStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] callIOState in
                self?.delegate?.callIOStateDidChange(to: callIOState)
            }
            .store(in: &cancelBags)

        callNodeClient?.remoteVideoOrientationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] videoOrientation in
                self?.delegate?.remoteVideoOrientationDidChanged(to: videoOrientation)
            }
            .store(in: &cancelBags)
//
//        callNodeClient.remoteVideoTrackPublisher
//            .receive(on: RunLoop.main)
//            .sink(receiveValue: { [weak self] remoteTrack in
//                self?.delegate?.remoteVideoTrackDidChange(to: remoteTrack)
//            })
//            .store(in: &cancelBags)

        call?.durationTimerPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] duration in
                self?.delegate?.durationDidChange(to: duration)
                let stats = self?.callNodeClient?.getConnectionStats()
                if let stats {
                    self?.delegate?.callDidUpdateConnectionStats(status: stats)
                }
            }
            .store(in: &cancelBags)

        call?.audioManager.onPortsChange = { [weak self] in
            DispatchQueue.main.async {
                self?.delegate?.audioPortChange(to: self?.call?.audioManager.currentPort)
            }
        }

        NotificationCenter.default
            .publisher(for: .startEndingCall)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.delegate?.startEndingCall(notification)
            }
            .store(in: &cancelBags)

        NotificationCenter.default
            .publisher(for: .callDidEnded)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.delegate?.callDidEnd(notification)
            }
            .store(in: &cancelBags)
    }

    // MARK: - Call action

    /// Create and start new outgoing call.
    public func startCall() async throws {
        guard let call else {
            throw ClientError("[CallController] Can not start call, no call available.")
        }
        try await call.createCall()
        try await CallManager.shared.reportOutgoingCallStarted(call)
    }

    /// End current call.
    public func endCall() throws {
        try CallManager.shared.endCall(with: call?.details.callId ?? "")
    }

    // MARK: - Control

    /// Switch camera position.
    public func switchCamera() {
        call?.toggleCameraPosition()
    }

    /// Set camera postion, throw error if failure.
    ///
    ///  - Parameters:
    ///   - position: New camera position want to set.
    public func setCameraPosition(_ position: CameraPosition) {
        call?.setCameraPosition(position)
    }

    /// Turn on/off video.
    public func togleVideo() {
        call?.toggleVideo()
    }

    /// Set video enable state
    ///
    ///  - Parameters:
    ///   - isEnabled: The boolean value for video enable state. if `true` video will be enabled and otherwise.
    public func setVideoEnabled(_ isEnabled: Bool) {
        call?.setVideoEnabled(isEnabled)
    }

    /// Set mic mute state
    ///
    ///  - Parameters:
    ///   - isMute: The boolean value for mic mute state. if `true` mic will be muted and otherwise.
    public func setMute(_ isMute: Bool) {
        call?.setMute(isMute)
    }

    /// Mute/unmute.
    public func toggleMute() {
        call?.toggleMute()
    }

    /// Get all available audio port
    public func getAllAudioPort() -> [AudioPort] {
        return call?.audioManager.allPort ?? []
    }

    /// Get all current audio port
    public func getCurrentAudioPort() -> AudioPort? {
        return call?.audioManager.currentPort
    }

    /// Set new audio port
    ///
    ///  - Parameters:
    ///     - port: The audio session port value to set.

    public func setAudioPort(_ port: AVAudioSession.Port) {
        call?.setAudioPort(port)
    }
}

// MARK: - Computed properties
package extension CallController {
    public var callDetails: CallDetails? {
        return call?.details
    }
    /// Current `CallIO` state which contain infomations about state of local and remote audio/video,
    /// camera position ...
    public var callIOState: CallIOState {
        return  callNodeClient?.callIOStatePublisher.value ?? CallIOState()
    }

    /// Current call state.
    public var callState: CallState {
        return call?.callStatePublisher.value ?? .ended
    }

    /// The duration of call
    public var duration: TimeInterval {
        return call?.durationTimerPublisher.value ?? 0
    }
}
