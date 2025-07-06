//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public struct MessageReactionData {
    public let type: MessageReactionType
    public let score: Int
    public let isChosenByCurrentUser: Bool

    public init(type: MessageReactionType, score: Int, isChosenByCurrentUser: Bool) {
        self.type = type
        self.score = score
        self.isChosenByCurrentUser = isChosenByCurrentUser
    }
}

public enum MessageReactionsBubbleStyle {
    case bigIncoming
    case smallIncoming
    case bigOutgoing
    case smallOutgoing
}

extension MessageReactionsBubbleStyle {
    var isBig: Bool {
        self == .bigIncoming || self == .bigOutgoing
    }

    var isIncoming: Bool {
        self == .bigIncoming || self == .smallIncoming
    }
}
