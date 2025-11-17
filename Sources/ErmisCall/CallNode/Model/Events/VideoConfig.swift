//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public struct VideoConfig: Codable, CallNodeEventProtocol {
    public var codec : String
    public var codedWidth : Int
    public var codedHeight : Int
    public var frameRate : Double
    public var orientation: Int
    public var description : String

    public var type: CallNodeEventType { .videoConfig }
    public var payload: Data {
        return (try? JSONEncoder().encode(self)) ?? Data()
    }

    public init?(payload: Data) {
        do {
            self = try JSONDecoder().decode(VideoConfig.self, from: payload)
        } catch {
            log.error("Failed to decode video config with error: \(error)")
            return nil
        }
    }

    public init(codec: String,
                codedWidth: Int,
                codedHeight: Int,
                frameRate: Double,
                orientation: Int,
                description: String) {
        self.codec = codec
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.frameRate = frameRate
        self.orientation = orientation
        self.description = description
    }
}
