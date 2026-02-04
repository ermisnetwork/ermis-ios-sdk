//
// Copyright 2025 Ermis Inc.
//

// A type which represent RTCMediaTrack Type.
struct TrackType: Codable, Hashable, RawRepresentable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}

extension TrackType {
    static let audio: Self = "audio"
    static let video: Self = "video"
}
