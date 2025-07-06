//
// Copyright 2025 Ermis Inc.
//

public enum CallAction: String, Codable {
    case createCall = "create-call"
    case acceptCall = "accept-call"
    case rejectCall = "reject-call"
    case missCall = "miss-call"
    case connectCall = "connect-call"
    case healthCall = "health-call"
    case endCall = "end-call"
    case signalCall = "signal-call"
    case upgradeCall = "upgrade-call"
}

