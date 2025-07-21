//
//  ComponentsProvider+Extension.swift
//  ErmisChat
//
//  Created by Tú Đinh on 21/7/25.
//

import UIKit

public protocol MessageBubbleProvidable {

    var isIncomingMessage: Bool { get }
}

public extension MessageBubbleProvidable where Self: UIView, Self: ThemeProvider {

    var isIncomingMessage: Bool {
        if let superview = superview(ofKind: MessageBubbleView.self) {
            return superview.backgroundColor == theme.colors.incommingBubbleMessageBackground
        }

        return false
    }
}
