//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type representing a message reaction. `MessageReaction` is an immutable snapshot
/// of a message reaction entity at the given time.
public struct MessageReaction: Hashable {
    /// The reaction type.
    public let type: MessageReactionType

    /// The reaction score.
    public let score: Int

    /// The date the reaction was created.
    public let createdAt: Date

    /// The date the reaction was last updated.
    public let updatedAt: Date

    /// The author.
    public let author: ChatUser
}
