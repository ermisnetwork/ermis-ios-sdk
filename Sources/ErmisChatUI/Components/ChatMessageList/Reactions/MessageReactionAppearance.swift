//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The type describing message reaction theme.
public protocol MessageReactionAppearanceType {
    var emojiString: String {get}
    var positionValue: Int {get}
}

/// The default `ReactionAppearanceType` implementation without any additional data
/// which can be used to provide custom icons for message reaction.
public struct MessageReactionAppearance: MessageReactionAppearanceType {
    public let emojiString: String
    public let positionValue: Int

    public init(emojiString: String, positionValue: Int) {
        self.emojiString = emojiString
        self.positionValue = positionValue
    }
}
