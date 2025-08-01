//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// An enum describing possible types of a channel.
public enum ChannelType: Codable, Hashable {
    case messaging
    case team
    case general
    case meeting
    case topic

    /// A channel type title.
    public var title: String { rawValue.capitalized }

    /// A raw value of the channel type.
    public var rawValue: String {
        switch self {
        case .messaging: return "messaging"
        case .team: return "team"
        case .general: return "general"
        case .meeting: return "meeting"
        case .topic: return "topic"
        }
    }

    /// Init a channel type with a string raw value.
    ///
    /// - Parameter rawValue: a string raw value of a channel type.
    init(rawValue: String) {
        switch rawValue {
        case "messaging":
            self = .messaging
        case "team":
            self = .team
        case "general":
            self = .general
        case "meeting":
            self = .meeting
        case "topic":
            self = .topic
        default:
            self = .meeting
            log.error("Unsupported channel type: \(rawValue), use .meeting as default")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
