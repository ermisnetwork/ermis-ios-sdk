//
// Copyright 2025 Ermis Inc.
//

import Foundation
import CoreMedia
import ErmisChat

public struct AudioFrame: CallNodeEventProtocol {
    public let timestamp: CMTime
    public let encodedFrame: Data

    public var type: CallNodeEventType { .audioFrame }

    public var payload: Data {
        let ptsMs = UInt64(CMTimeConvertScale(timestamp, timescale: 1_000_000_000, method: .default).value)
        var timestampBE = ptsMs.bigEndian
        let timeStampData = Data(
            bytes: &timestampBE,
            count: MemoryLayout<UInt64>.size
        )
        var data = timeStampData
        data.append(encodedFrame)
        return data
    }

    public init?(payload: Data) {
        guard payload.count > 8 else {
            log.error("Failed to parse AudioFrame: data is too short (\(payload.count) bytes")
            return nil
        }
        let timestampBytes = payload.prefix(8)
        let timestampValue: UInt64 = timestampBytes.withUnsafeBytes { raw in
            var val: UInt64 = 0
            memcpy(&val, raw.baseAddress!, 8)
            return UInt64(bigEndian: val)
        }

        timestamp = CMTime(value: CMTimeValue(timestampValue), timescale: 1_000_000_000)
        encodedFrame = payload.subdata(in: 8..<payload.count)
    }

    public init(timestamp: CMTime, encodedFrame: Data) {
        self.timestamp = timestamp
        self.encodedFrame = encodedFrame
    }
}

