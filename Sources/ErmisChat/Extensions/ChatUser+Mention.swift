//
// Copyright 2025 Ermis Inc.
//

import ErmisChat

public
extension ChatUser {
    var mentionString: String {
        return "@" + self.userId
    }

    var mentionsDisplayString: String {
        return "@" + (self.name ?? self.userId)
    }
}
