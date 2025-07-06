//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class DefaultReactionPickerBubbleView: ReactionPickerBubbleView {
    // MARK: - Subviews

    public let contentViewBackground = UIView().withoutAutoresizingMaskConstraints
    public let tailBehind = UIImageView().withoutAutoresizingMaskConstraints
    public let tailInFront = UIImageView().withoutAutoresizingMaskConstraints

    override open var tailLeadingAnchor: NSLayoutXAxisAnchor { tailBehind.leadingAnchor }
    override open var tailTrailingAnchor: NSLayoutXAxisAnchor { tailBehind.trailingAnchor }

    // MARK: - Overrides

    override open func layoutSubviews() {
        super.layoutSubviews()

        contentViewBackground.layer.cornerRadius = contentViewBackground.bounds.height / 2
    }

    override open func setUpTheme() {
        super.setUpTheme()
        contentViewBackground.layer.borderWidth = 1
    }

    override open func setUpUI() {
        addSubview(tailBehind)
        contentViewBackground.addSubview(contentView)
        contentViewBackground.insetsLayoutMarginsFromSafeArea = false
        contentView.pin(to: contentViewBackground.layoutMarginsGuide)
        embed(contentViewBackground)
        addSubview(tailInFront)

        NSLayoutConstraint.activate([
            tailBehind.centerXAnchor.pin(equalTo: contentViewBackground.centerXAnchor).with(priority: .defaultLow),
            tailBehind.centerYAnchor.pin(equalTo: contentViewBackground.bottomAnchor),
            tailInFront.centerXAnchor.pin(equalTo: tailBehind.centerXAnchor),
            tailInFront.centerYAnchor.pin(equalTo: tailBehind.centerYAnchor)
        ])
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        tailBehind.image = tailBackImage
        tailInFront.image = tailFrontImage
        contentViewBackground.backgroundColor = contentBackgroundColor
        contentViewBackground.layer.borderColor = contentBorderColor.cgColor
        contentViewBackground.directionalLayoutMargins = contentLayoutMargins
    }

    open var contentLayoutMargins: NSDirectionalEdgeInsets {
        guard let content = content else { return .zero }

        return content.style.isBig ?
            .init(top: 8, leading: 16, bottom: 8, trailing: 16) :
            .init(top: 4, leading: 4, bottom: 4, trailing: 4)
    }

    open var contentBackgroundColor: UIColor {
        guard let content = content else { return .clear }

        switch content.style {
        case .bigIncoming, .bigOutgoing, .smallOutgoing:
            return theme.colors.surfaceContainer
        case .smallIncoming:
            return theme.colors.surfaceContainerLow
        }
    }

    open var contentBorderColor: UIColor {
        guard let content = content else { return .clear }

        let color: UIColor
        switch content.style {
        case .smallOutgoing:
            color = theme.colors.outline
        case .smallIncoming:
            color = theme.colors.outline
        default:
            color = contentBackgroundColor
        }
        return resolvedColor(color)
    }

    open var tailBackImage: UIImage? {
        guard let content = content else { return nil }

        switch content.style {
        case .bigIncoming, .bigOutgoing:
            return .tail(
                options: .large(flipped: content.style.isIncoming),
                colors: .init(
                    outlineColor: .clear,
                    borderColor: .clear,
                    innerColor: contentBorderColor
                )
            )
        case .smallIncoming, .smallOutgoing:
            let borderColor = content.style.isIncoming ?
            theme.colors.outline :
            theme.colors.outline

            let innerColor = content.style.isIncoming ?
            theme.colors.surfaceContainerLow :
                theme.colors.surfaceContainer

            return .tail(
                options: .small(flipped: content.style.isIncoming),
                colors: .init(
                    outlineColor: resolvedColor(theme.colors.surface),
                    borderColor: resolvedColor(borderColor),
                    innerColor: resolvedColor(innerColor)
                )
            )
        }
    }

    open var tailFrontImage: UIImage? {
        guard let content = content else { return nil }

        switch content.style {
        case .bigIncoming, .bigOutgoing:
            return nil
        case .smallIncoming, .smallOutgoing:
            let innerColor = content.style.isIncoming ?
            theme.colors.surfaceContainerLow :
                theme.colors.surfaceContainer
            return .tail(
                options: .small(flipped: content.style.isIncoming),
                colors: .init(
                    outlineColor: .clear,
                    borderColor: .clear,
                    innerColor: resolvedColor(innerColor)
                )
            )
        }
    }

    /// Returns color resolved with current `traitCollection`.
    /// This is needed when a `cgColor` is used which can not be resolved by the view itself.
    private func resolvedColor(_ color: UIColor) -> UIColor {
        return color.resolvedColor(with: traitCollection)
    }
}
