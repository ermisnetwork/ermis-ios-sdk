//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class ReactionBubbleBaseView: _View, ThemeProvider {
    open var tailDirection: ThreadArrowView.Direction? {
        didSet { updateContentIfNeeded() }
    }
}

open class ReactionsBubbleView: ReactionBubbleBaseView {

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = .clear
    }

    override open func draw(_ rect: CGRect) {
        super.draw(rect)

        strokeColor?.setStroke()
        fillColor?.setFill()

        let bubblePath = bubblePath()
        bubblePath.stroke()
        bubblePath.fill()
    }

    override open func setUpUI() {
        super.setUpUI()
        clipsToBounds = true
        directionalLayoutMargins = .init(top: 0,
                                         leading: 8,
                                         bottom: 0,
                                         trailing: 8)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        setNeedsDisplay()
    }

    /// Bubble's background color.
    open var fillColor: UIColor? {
        theme.colors.reactionBubbleBackground
    }

    /// Bubble's border color.
    open var strokeColor: UIColor? {
        theme.colors.reactionBubbleBorder
    }

    /// The center of bubble's body.
    open var bubbleBodyCenter: CGPoint {
        bounds.center
    }

    /// The path combined from bubble's body path and bubble's tail path.
    open func bubblePath() -> UIBezierPath {
        let borderWidth: CGFloat = 1
        let bubbleBodyRect = CGRect(
            center: bubbleBodyCenter,
            size: .init(
                width: bounds.width - borderWidth / 2,
                height: bounds.height - borderWidth / 2
            )
        )

        let bubbleBodyPath = UIBezierPath(
            roundedRect: bubbleBodyRect,
            cornerRadius: bubbleBodyRect.height / 2
        )

        return bubbleBodyPath
    }
}
