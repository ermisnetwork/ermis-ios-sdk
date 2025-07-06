//
// Copyright 2025 Ermis Inc.
//

import StreamWebRTC
import ErmisChat

/// A factory for create PeerConnection, media tracks object.
class PeerConnectionFactory {
    /// WebRTC peerconnection factory.
    private let pcFactory: RTCPeerConnectionFactory

    init() {
        RTCInitializeSSL()
        let defaultVideoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoEncoderFactory = RTCVideoEncoderFactorySimulcast(primary: defaultVideoEncoderFactory, fallback: defaultVideoEncoderFactory)
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.pcFactory = RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        let options = RTCPeerConnectionFactoryOptions()
    }

    /// Build a peer connection instance.
    ///
    /// - Parameters:
    ///    - configuration: The WebRTC configuration.
    ///    - constraints: The WebRTC media constraints.
    ///    - delegate: The `PeerConnectionDelegate` object.
    /// - Returns:  An instance of `PeerConnection` object or throw `Error`.
    func makePeerConnection(configuration: RTCConfiguration,
                            constraints: RTCMediaConstraints = .default,
                            delegate: PeerConnectionDelegate?) throws -> PeerConnection {
        guard let rtcPeerConnection = pcFactory.peerConnection(with: configuration,
                                                               constraints: constraints,
                                                               delegate: nil) else {
            throw ClientError.PeerConnectionCreatedFailed()
        }
        let peerConnection = PeerConnection(pc: rtcPeerConnection,
                                            delegate: delegate)
        rtcPeerConnection.delegate = peerConnection
        return peerConnection
    }

    /// Create a `RTCVideoSource` object.
    ///
    /// - Parameters:
    ///    - screencast: A Boolean value, `true` if create screencast video source.
    /// - Returns: An instance of `RTCVideoSource` object.
    func createVideoSource(for screencast: Bool) -> RTCVideoSource {
        pcFactory.videoSource(forScreenCast: screencast)
    }

    /// Create a `RTCVideoTrack` object.
    ///
    /// - Parameters:
    ///    - source: The video source object of video track.
    /// - Returns: An instance of `RTCVideoTrack` object.
    func createVideoTrack(with source: RTCVideoSource) -> RTCVideoTrack {
        pcFactory.videoTrack(with: source, trackId: generateTrackId(trackType: .video))
    }

    /// Create a `RTCAudioSource` object.
    ///
    /// - Parameters:
    ///    - constraints: The `RTCMediaConstraints` object for the audio source.
    /// - Returns: An instance of `RTCAudioSource` object.
    func createAudioSource(with constraints: RTCMediaConstraints) -> RTCAudioSource {
        pcFactory.audioSource(with: constraints)
    }

    /// Create a `RTCAudioTrack` object.
    ///
    /// - Parameters:
    ///    - source: The video source object of audio track.
    /// - Returns: An instance of `RTCAudioTrack` object.
    func createAudioTrack(with source: RTCAudioSource) -> RTCAudioTrack {
        pcFactory.audioTrack(with: source, trackId: generateTrackId(trackType: .audio))
    }
    // MARK: - Helper
    private func generateTrackId(trackType: TrackType) -> String {
        return trackType.rawValue + "_" + "iOS" + "_" + UUID().uuidString.lowercased()
    }
}
