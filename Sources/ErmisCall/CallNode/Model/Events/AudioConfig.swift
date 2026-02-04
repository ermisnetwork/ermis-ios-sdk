//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public struct AudioConfig: Codable, CallNodeEventProtocol {
    public var sampleRate : Int
    public var numberOfChannels : Int
    public var codec : String
    public var description : String

    public var type: CallNodeEventType {
        return .audioConfig
    }

    public var payload: Data {
        return (try? JSONEncoder().encode(self)) ?? Data()
    }

    public init?(payload: Data) {
        do {
            self = try JSONDecoder().decode(AudioConfig.self, from: payload)
        } catch {
            log.error("Failed to decode audio config with error: \(error)")
            return nil
        }
    }

    public init(sampleRate: Int, numberOfChannels: Int, codec: String, description: String) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.codec = codec
        self.description = description
    }
}
