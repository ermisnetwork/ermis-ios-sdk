//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that shows a number of unread messages on the Scroll-To-Latest-Message button in the Message List.
open class MessageListUnreadCountView: UnreadCountView {
    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = tintColor
    }
}
