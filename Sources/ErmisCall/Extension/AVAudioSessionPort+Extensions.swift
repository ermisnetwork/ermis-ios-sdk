//
// Copyright 2025 Ermis Inc.
//

import AVFAudio

extension AVAudioSession.Port {
    var isBuiltIn: Bool {
        switch self {
        case .builtInSpeaker, .builtInReceiver:
            return true
        default:
            return false
        }
    }

    var isBlueTooth: Bool {
        switch self {
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP:
            return true
        default:
            return false
        }
    }
}
