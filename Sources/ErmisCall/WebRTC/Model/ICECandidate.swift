//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import StreamWebRTC

// A type which represent WebRTC ICECandidate.
public struct ICECandidate: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32

    static let separator: String = "$"

    var sdpString: String {
        let candidate = candidate
        let sdpMid = sdpMid ?? ""
        let sdpMLineIndex = String(sdpMLineIndex)
        return [sdpMid, sdpMLineIndex, candidate].joined(separator: ICECandidate.separator)
    }

    var rtcICE: RTCIceCandidate {
        return RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }

    init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }

    init(rtcICE: RTCIceCandidate) {
        self.candidate = rtcICE.sdp
        self.sdpMid = rtcICE.sdpMid
        self.sdpMLineIndex = rtcICE.sdpMLineIndex
    }

    init?(from sdpString: String) {
        let components = sdpString.components(separatedBy: ICECandidate.separator)
        guard components.count == 3, let mlineIndex = Int32(components[1]) else {
            log.debug("[ErmisCall] Can not parse ICECandidate from \(sdpString).")
            return nil
        }
        self.sdpMid = components[0]
        self.sdpMLineIndex = mlineIndex
        self.candidate = components[2]
    }
}
