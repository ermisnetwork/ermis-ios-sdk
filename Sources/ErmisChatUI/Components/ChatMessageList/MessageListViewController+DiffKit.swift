//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

extension MessageListViewController {
    /// Set the previous message snapshot before the data controller reports new messages.
    internal func setPreviousMessagesSnapshot(_ messages: [ChatMessage]) {
        listView.previousMessagesSnapshot = messages
    }

    /// Set the new message snapshot reported by the data controller.
    internal func setNewMessagesSnapshot(_ messages: LazyCachedMapCollection<ChatMessage>) {
        listView.currentMessagesFromDataSource = messages
        listView.newMessagesSnapshot = messages
    }
}
