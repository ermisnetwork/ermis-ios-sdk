//
// Copyright 2025 Ermis Inc.
//

import Foundation
import VideoToolbox
import AVFoundation
import AudioToolbox

public enum AudioCodec {
    case opus
    case aac

    var frameSize: Int {
        switch self {
        case .opus:
            return 960
        case .aac:
            return 1024
        }
    }

    var sampleRate: Double {
        switch self {
        case .opus:
            return 48_000
        case .aac:
            return 48_000
        }
    }

    var numberOfChannels: Int32 {
        switch self {
        case .opus:
            return 1
        case .aac:
            return 2
        }
    }

    var bitrate: UInt32 {
        switch self {
        case .opus:
            return 64_000
        case .aac:
            return 64_000
        }
    }
}
