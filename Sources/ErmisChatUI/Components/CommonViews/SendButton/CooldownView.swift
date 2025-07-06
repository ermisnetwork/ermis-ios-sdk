//
// Copyright 2025 Ermis Inc.
//

import UIKit

/// A view showing a cooldown when Slow Mode is active.
open class CooldownView: _View, ThemeProvider {
    public struct Content {
        public var cooldown: Int
    }

    open var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    public private(set) lazy var cooldownLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "cooldownLabel")

    public lazy var formatter = {
        let formater = DateComponentsFormatter()
        formater.allowedUnits = [.minute, .second]
        formater.unitsStyle = .positional
        formater.zeroFormattingBehavior = .pad
        return formater
    }()

    override open func contentDidChanged() {
        super.contentDidChanged()

        cooldownLabel.text = content.map { formatter.string(from: TimeInterval($0.cooldown)) ?? "" }
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(cooldownLabel, insets: .init(top: 6, leading: 10, bottom: 6, trailing: 10))
        cooldownLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        widthAnchor.pin(greaterThanOrEqualTo: heightAnchor).isActive = true
    }

    override open func setUpTheme() {
        super.setUpTheme()

        clipsToBounds = true
        backgroundColor = theme.colors.surfaceContainerHighest
        cooldownLabel.font = theme.fonts.body.bold
        cooldownLabel.textColor = theme.colors.inverseOnSurface
        cooldownLabel.adjustsFontForContentSizeCategory = true
    }
}
