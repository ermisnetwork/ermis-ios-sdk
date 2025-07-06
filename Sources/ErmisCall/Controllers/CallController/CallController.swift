//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import StreamWebRTC
import UIKit
import Combine

public
protocol CallControllerDelegate: AnyObject {
    func callStateDidChange(to callState: CallState)
    func callConnectionStatusDidChange(to connectionStatus: CallConnectionStatus)
    func callIOStateDidChange(to callIOState: CallIOState)
    func remoteVideoTrackDidChange(to remoteVideoTrack: RTCVideoTrack?)
    func durationDidChange(to duration: TimeInterval)
    func audioPortChange(to port: AudioPort?)
    func callDidEnd(_ notification: Notification)
}

public
class CallController: NSObject {
    public let channel: Channel
    public let call: Call

    public weak var delegate: CallControllerDelegate?

    private var cancelBags: Set<AnyCancellable> = []

    public var webRTCClient: WebRTCClient {
        return call.webRTCClient
    }


    public init(with channel: Channel, call: Call) {
        self.channel = channel
        self.call = call
    }

    // MARK: - Observer
    /// Start observer call. You can handle all changes via `CallControllerDelegate`.
    package func startCallObservers() {
        call.callStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] callState in
                self?.delegate?.callStateDidChange(to: callState)
            }
            .store(in: &cancelBags)

        call.connectionStatusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionStatus in
                self?.delegate?.callConnectionStatusDidChange(to: connectionStatus)
            }
            .store(in: &cancelBags)

        webRTCClient.callIOStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] callIOState in
                self?.delegate?.callIOStateDidChange(to: callIOState)
            }
            .store(in: &cancelBags)

        webRTCClient.remoteVideoTrackPublisher
            .receive(on: RunLoop.main)
            .sink(receiveValue: { [weak self] remoteTrack in
                self?.delegate?.remoteVideoTrackDidChange(to: remoteTrack)
            })
            .store(in: &cancelBags)

        call.durationTimerPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] duration in
                self?.delegate?.durationDidChange(to: duration)
            }
            .store(in: &cancelBags)

        call.audioManager.onPortsChange = { [weak self] in
            self?.delegate?.audioPortChange(to: self?.call.audioManager.currentPort)
        }

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
        try await call.createCall()
        CallManager.shared.reportOutgoingCallStarted(call)
    }

    /// End current call.
    public func endCall() async throws {
        try await CallManager.shared.endCall(call)
    }

    // MARK: - Control

    /// Switch camera position.
    public func switchCamera() {
        call.toggleCameraPosition()
    }

    /// Set camera postion, throw error if failure.
    ///
    ///  - Parameters:
    ///   - position: New camera position want to set.
    public func setCameraPosition(_ position: CameraPosition) {
        call.setCameraPosition(position)
    }

    /// Turn on/off video.
    public func togleVideo() {
        call.toggleVideo()
    }

    /// Set video enable state
    ///
    ///  - Parameters:
    ///   - isEnabled: The boolean value for video enable state. if `true` video will be enabled and otherwise.
    public func setVideoEnabled(_ isEnabled: Bool) {
        call.setVideoEnabled(isEnabled)
    }

    /// Set mic mute state
    ///
    ///  - Parameters:
    ///   - isMute: The boolean value for mic mute state. if `true` mic will be muted and otherwise.
    public func setMute(_ isMute: Bool) {
        call.setMute(isMute)
    }

    /// Mute/unmute.
    public func toggleMute() {
        call.toggleMute()
    }

    /// Get all available audio port
    public func getAllAudioPort() -> [AudioPort] {
        return call.audioManager.allPort
    }

    /// Get all current audio port
    public func getCurrentAudioPort() -> AudioPort? {
        return call.audioManager.currentPort
    }

    /// Set new audio port
    ///
    ///  - Parameters:
    ///     - port: The audio session port value to set.

    public func setAudioPort(_ port: AVAudioSession.Port) {
        call.setAudioPort(port)
    }

    /// Render local video to the renderer.
    ///
    /// - Parameters:
    ///    - renderer: The renderer to render local video track in.
    public func renderLocalVideo(to renderer: RTCVideoRenderer) {
        webRTCClient.renderLocalVideo(to: renderer)
    }

    /// Render remote video to the renderer.
    ///
    /// - Parameters:
    ///    - renderer: The renderer to render remote video track in.
    public func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        webRTCClient.renderRemoteVideo(to: renderer)
    }
    // MARK: -
}

// MARK: - Computed properties
package extension CallController {
    public var callDetails: CallDetails {
        return call.details
    }
    /// Current `CallIO` state which contain infomations about state of local and remote audio/video,
    /// camera position ...
    public var callIOState: CallIOState {
        return  webRTCClient.callIOStatePublisher.value
    }

    /// Current call state.
    public var callState: CallState {
        return call.callStatePublisher.value
    }

    /// The duration of call
    public var duration: TimeInterval {
        return call.durationTimerPublisher.value
    }
}
