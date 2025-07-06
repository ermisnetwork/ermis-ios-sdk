//
// Copyright 2025 Ermis Inc.
//

import StreamWebRTC

extension RTCConfiguration {
    convenience init(with iceServers: [ICEServer] = []) {
        self.init()
        let rtcIceServers: [RTCIceServer] = iceServers.map { $0.toRTCICEServer() }
        self.iceServers = rtcIceServers
        self.sdpSemantics = .unifiedPlan
    }
}

