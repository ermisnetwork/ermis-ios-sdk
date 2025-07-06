//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class LoadingIndicator: _View, ThemeProvider {
    override open var isHidden: Bool {
        didSet { updateContentIfNeeded() }
    }

    open var rotationPeriod: TimeInterval = 1

    // MARK: - Subviews

    public private(set) lazy var imageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    // MARK: - Overrides

    override open func setUpTheme() {
        super.setUpTheme()
        imageView.image = theme.icons.loadingIndicator
    }

    override open func setUpUI() {
        embed(imageView)
        widthAnchor.pin(equalTo: heightAnchor).isActive = true
    }

    override open func contentDidChanged() {
        isHidden ? stopRotating() : startRotation()
    }

    static var kRotationAnimationKey: String { "rotationanimationkey" }

    open func startRotation() {
        guard layer.animation(forKey: Self.kRotationAnimationKey) == nil else { return }

        let rotationAnimation = CABasicAnimation(keyPath: "transform.rotation")
        rotationAnimation.fromValue = 0.0
        rotationAnimation.toValue = Float.pi * 2.0
        rotationAnimation.duration = rotationPeriod
        rotationAnimation.repeatCount = Float.infinity

        layer.add(rotationAnimation, forKey: Self.kRotationAnimationKey)
    }

    open func stopRotating() {
        layer.removeAnimation(forKey: Self.kRotationAnimationKey)
    }
}
