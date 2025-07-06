//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays a bubble around a message.
open class MessageBubbleView: _View, ThemeProvider, SwiftUIRepresentable {
    /// A type describing the content of this view.
    public struct Content {
        /// The background color of the bubble.
        public let backgroundColor: UIColor
        /// The mask saying which corners should be rounded.
        public let roundedCorners: CACornerMask

        public init(backgroundColor: UIColor, roundedCorners: CACornerMask) {
            self.backgroundColor = backgroundColor
            self.roundedCorners = roundedCorners
        }
    }

    /// The content this view is rendered based on.
    open var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    open override func setUp() {
        super.setUp()
        layer.cornerRadius = 12
        layer.borderWidth = 1
    }

    override open func setUpTheme() {
        super.setUpTheme()

        layer.borderColor = theme.colors.outline.cgColor
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        layer.maskedCorners = content?.roundedCorners ?? .all
        backgroundColor = content?.backgroundColor ?? .clear
    }
}
