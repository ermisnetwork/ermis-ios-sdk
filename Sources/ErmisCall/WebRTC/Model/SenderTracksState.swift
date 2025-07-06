//
// Copyright 2025 Ermis Inc.
//

import Foundation
import AVFoundation

public enum CameraPosition {
    case front
    case back

    var captureDevicePosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }

    public func flip() -> CameraPosition {
        switch self {
        case .front: return .back
        case .back: return .front
        }
    }
}

/// A class represent state of input, output medias.
public final class CallIOState {
    // Local audio is enable or not.
    public var isAudioEnabled: Bool = true
    // Local video is enable or not.
    public var isVideoEnabled: Bool = true
    // Remote audio is enable or not.
    public var isRemoteAudioEnable: Bool = true
    // Remote video is enable or not.
    public var isRemoteVideoEnabled: Bool = true
    // Current camera position.
    public var cameraPosition: CameraPosition = .front

    public var hasInput: Bool {
        isAudioEnabled || isVideoEnabled
    }

    public
    init(isAudioEnabled: Bool = true,
         isVideoEnabled: Bool = false,
         isRemoteAudioEnabled: Bool = true,
         isRemoteVideoEnabled: Bool = false,
         cameraPosition: CameraPosition = .front) {
        self.isAudioEnabled = isAudioEnabled
        self.isVideoEnabled = isVideoEnabled
        self.isRemoteAudioEnable = isRemoteAudioEnabled
        self.isRemoteVideoEnabled = isRemoteVideoEnabled
        self.cameraPosition = cameraPosition
    }
}

extension CallIOState: Equatable {
    public static func == (lhs: CallIOState, rhs: CallIOState) -> Bool {
        lhs.isAudioEnabled == rhs.isAudioEnabled
        && lhs.isVideoEnabled == rhs.isVideoEnabled
        && lhs.isRemoteAudioEnable == rhs.isRemoteAudioEnable
        && lhs.isRemoteVideoEnabled == rhs.isRemoteVideoEnabled
        && lhs.cameraPosition == rhs.cameraPosition
    }
}
