//
// Copyright 2025 Ermis Inc.
//

import UIKit

public protocol MessageBubbleProvidable {

    var isIncomingMessage: Bool { get }
}

public extension MessageBubbleProvidable where Self: UIView, Self: ThemeProvider {

    var isIncomingMessage: Bool {
        if let superview = superview(ofKind: MessageContentView.self) {
            return !(superview.content?.isSentByCurrentUser ?? false)
        }

        return false
    }
}
