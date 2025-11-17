//
// Copyright 2025 Ermis Inc.
//

public enum CallNodeEventType {
    case videoConfig
    case audioConfig
    case videoKeyFrame
    case videoDeltaFrame
    case audioFrame
    case orientation
    case connected
    case transciver
    case requestConfig
    case requestKeyframe
    case unknown

    var rawValue: UInt8 {
        switch self {
        case .videoConfig:
            return 0
        case .audioConfig:
            return 1
        case .videoKeyFrame:
            return 2
        case .videoDeltaFrame:
            return 3
        case .audioFrame:
            return 4
        case .orientation:
            return 5
        case .connected:
            return 6
        case .transciver:
            return 7
        case .requestConfig:
            return 8
        case .requestKeyframe:
            return 9
        default:
            return 255
        }
    }

    public init(with value: UInt8) {
        switch value {
        case 0:
            self = .videoConfig
        case 1:
            self = .audioConfig
        case 2:
            self = .videoKeyFrame
        case 3:
            self = .videoDeltaFrame
        case 4:
            self = .audioFrame
        case 5:
            self = .orientation
        case 6:
            self = .connected
        case 7:
            self = .transciver
        default:
            self = .unknown
        }
    }
}

