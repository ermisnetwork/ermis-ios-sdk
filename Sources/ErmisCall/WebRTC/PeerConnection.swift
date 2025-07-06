//
// Copyright 2025 Ermis Inc.
//

import StreamWebRTC
import ErmisChat

/// `PeerConnection` uses this protocol to communicate events to the delegate.
protocol PeerConnectionDelegate: AnyObject {
    func peerConnectionShouldNegotiate(_ peerConnection: PeerConnection)
    func peerConnection(_ peerConnection: PeerConnection, didChange connectionState: RTCPeerConnectionState)
    func peerConnection(_ peerConnection: PeerConnection, didAddStream stream: RTCMediaStream)
    func peerConnection(_ peerConnection: PeerConnection, didRemoveStream stream: RTCMediaStream)
    func peerConnection(_ peerConnection: PeerConnection, didGenerate candidate: ICECandidate)
    func peerConnection(_ peerConnection: PeerConnection, didOpen dataChannel: RTCDataChannel)
}

/// The custom type which represent `RTCPeerConnection`
class PeerConnection: NSObject {
    /// An instance of `RTCPeerConnection`
    private let pc: RTCPeerConnection

    /// List of pending `RTCIceCandidate`, we be sent after set remote SDP.
    private var pendingICECandidates: [RTCIceCandidate] = []

    /// An instance of `PeerConnectionDelegate` protocol.
    weak var delegate: PeerConnectionDelegate?

    /// Connection state of peerConnection.
    var connectionState: RTCPeerConnectionState {
        return pc.connectionState
    }

    /// List of transceiver of peerConnection.
    var transceivers: [RTCRtpTransceiver] {
        return pc.transceivers
    }

    /// List of sender of peerConnection.
    var senders: [RTCRtpSender] {
        return pc.senders
    }

    /// List of receiver of peerConnection.
    var receivers: [RTCRtpReceiver] {
        return pc.receivers
    }

    /// Create new `PeerConnection` intance.
    ///
    /// - Parameters:
    ///    - pc: instance of `RTCPeerConnection`
    ///    - delegate: `PeerConnectionDelegate` instance for handle peerConnection delegate events.
    /// - Returns: An instance of `PeerConnection` object.
    init(pc: RTCPeerConnection,
         delegate: PeerConnectionDelegate?) {
        self.pc = pc
        self.delegate = delegate
        super.init()
        pc.delegate = self
    }

    // MARK: - Signal
    /// Create offer message.
    ///
    /// - Parameters:
    ///    - constraints: The media constraint of this offer.
    /// - Returns: An offer SDP, Throws error if not successful
    func createOffer(with constraints: RTCMediaConstraints) async throws -> SDP {
        let sdp = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(sdp)
        return sdp
    }

    /// Create answer message.
    ///
    /// - Parameters:
    ///    - constraints: The media constraint of this offer.
    /// - Returns: An answers SDP, throws error if not successful.
    func createAnswer(with constraints: RTCMediaConstraints) async throws -> SDP {
        let sdp = try await pc.answer(for: constraints)
        try await pc.setLocalDescription(sdp)
        return sdp
    }

    /// Set remote SDP.
    ///
    /// - Parameters:
    ///    - sdp: The remote sdp.
    ///    - type: Type of sdp
    /// - Returns: Throws error if not successful.
    @MainActor
    func setRemoteSDP(sdp: String, type: RTCSdpType) async throws {
        let sdp = RTCSessionDescription(type: type, sdp: sdp)
        try await pc.setRemoteDescription(sdp)
        for candidate in pendingICECandidates {
            _ = try await self.add(iceCandidate: candidate)
        }
        self.pendingICECandidates = []
    }

    /// Add ice candidate to peer connection.
    ///
    /// - Parameters:
    ///    - iceCandidate: The ice candidate.
    /// - Returns: Throws error if not successful.
    @MainActor
    func add(iceCandidate: RTCIceCandidate) async throws {
        guard pc.remoteDescription != nil else {
            pendingICECandidates.append(iceCandidate)
            return
        }
        try await pc.add(iceCandidate)
    }

    /// Add track to peer connection.
    ///
    /// - Parameters:
    ///    - track: The media track.
    ///    - streamIds: The identifier list of stream.
    ///    - trackType: The media track type, can be "audio" or "video"
    func addTrack(_ track: RTCMediaStreamTrack?,
                          streamIds: [String],
                          trackType: TrackType) {
        guard let track else { return }
        pc.add(track, streamIds: streamIds)
    }

    /// Update RTC configuration for peerConnection.
    ///
    /// - Parameters:
    ///    - configuration: The updated configuration.
    func update(configuration: RTCConfiguration?) {
        guard let configuration else { return }
        pc.setConfiguration(configuration)
    }

    /// Create webRTC data channel.
    ///
    /// - Returns: An instance of `RTCDataChannel` object.
    func createDataChannel() -> RTCDataChannel? {
        let configuration = RTCDataChannelConfiguration()
        guard let dataChannel = pc.dataChannel(forLabel: "rtc_data_channel", configuration: configuration) else {
            log.warning("[WebRTC] can not create data channel")
            return nil
        }
        return dataChannel
    }

    /// Close peerConnection.
    func close() {
        pc.close()
    }    
}
// MARK: - RTCPeerConnectionDelegate
extension PeerConnection: RTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        log.debug("[WebRTC] Peerconnection Should Negotiate.",
                  subsystems: .webRTC)
        delegate?.peerConnectionShouldNegotiate(self)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log.debug("[WebRTC] Peerconnection Signaling state did change to: \(stateChanged)",
                  subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        log.debug("[WebRTC] Peerconnection did remove media stream: \(stream.streamId)",
                  subsystems: .webRTC)
        delegate?.peerConnection(self, didRemoveStream: stream)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        log.debug("[WebRTC] Peerconnection did add media stream: \(stream.streamId)",
                  subsystems: .webRTC)
        delegate?.peerConnection(self, didAddStream: stream)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.debug("[WebRTC] Peerconnection did change ICE state: \(newState)", subsystems: .webRTC)
        let message = "[WebRTC] Ice connection state did change to: \(newState)"
        if case .failed = newState {
            log.error(message, subsystems: .webRTC)
        } else {
            log.debug(message, subsystems: .webRTC)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log.debug("[WebRTC] Ice gathering state did change to: \(newState)",
                  subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        log.debug("[WebRTC] Peerconnection did generate candidate: \(candidate)",
                  subsystems: .webRTC)
        let iceCandidate = ICECandidate(rtcICE: candidate)
        delegate?.peerConnection(self, didGenerate: iceCandidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        log.debug("[WebRTC] Peerconnection did remove media candidates: \(candidates)",
                  subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log.debug("[WebRTC] Peerconnection did open data channel: \(dataChannel.label)",
                  subsystems: .webRTC)
        delegate?.peerConnection(self, didOpen: dataChannel)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        log.debug("[WebRTC] Peerconnection did start receiving on transceiver: \(transceiver)", subsystems: .webRTC)

    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log.debug("[WebRTC] Peerconnection did changed connection state: \(newState)", subsystems: .webRTC)
        delegate?.peerConnection(self, didChange: newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        log.debug("[WebRTC] Peerconnection did remove rtcReceiver: \(rtpReceiver)", subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        log.debug("[WebRTC] Peerconnection did add rtcReceiver: \(rtpReceiver)", subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {
        log.debug("[WebRTC] Peerconnection did failed to gather ice: \(event)", subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeStandardizedIceConnectionState newState: RTCIceConnectionState) {
        log.debug("[WebRTC] Peerconnection did change standardized ice connection state: \(newState)", subsystems: .webRTC)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs lastDataReceivedMs: Int32, changeReason reason: String) {
        log.debug("[WebRTC] Peerconnection did change local ice ice candidate: \(reason)", subsystems: .webRTC)
    }
}
