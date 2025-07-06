//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type representing a message edit history. `MessageEditHistory` is an immutable snapshot
/// of a message edit history entity at the given time.
public struct MessageEditHistory: Hashable {
    /// The history text message.
    public let text: String
    /// The date the edit text was created.
    public let createdAt: Date
}
