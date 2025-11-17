//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public struct VideoOrientation {
    public let rotation: CGFloat
}

extension VideoOrientation: CallNodeEventProtocol {
    public var type: CallNodeEventType { .orientation }
    public var payload: Data {
        var rotationBE = UInt32(self.rotation).bigEndian
        let orientationData = Data(
            bytes: &rotationBE,
            count: MemoryLayout<UInt32>.size
        )
        return orientationData
    }

    public init?(payload: Data) {
        guard payload.count > 1 else {
            print("Failed to parse VideoFrame: data is too short (\(payload.count) bytes")
            return nil
        }
        let rotationValue: UInt32 = payload.withUnsafeBytes { raw in
            var val: UInt32 = 0
            memcpy(&val, raw.baseAddress!, 2)
            return UInt32(bigEndian: val)
        }
        rotation = CGFloat(rotationValue)
    }
}
