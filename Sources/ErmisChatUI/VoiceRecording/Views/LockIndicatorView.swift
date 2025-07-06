//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

/// A component used to show the (un)locked state of the recording flow.
open class LockIndicatorView: _View, UIProvider {
    public var content: Bool = false {
        didSet { updateContentIfNeeded() }
    }

    // MARK: - UI Components

    /// The main container where all components will be added into.
    open lazy var mainContainer: UIStackView = .init()
        .withoutAutoresizingMaskConstraints

    /// The container stackView that all lockView related UI components will be added.
    open lazy var lockContainerStackView: UIStackView = .init()
        .withoutAutoresizingMaskConstraints

    /// A view that is being used to provide a background colour and cornerRadius to the lockView.
    open lazy var lockView: UIView = .init()
        .withoutAutoresizingMaskConstraints

    /// The stackView that contains by default the lockView image and the up chevron.
    open lazy var lockViewStackView: UIStackView = .init()
        .withoutAutoresizingMaskConstraints

    /// The imageView that by default shows the lock image.
    open lazy var lockImageView: UIImageView = .init()
        .withoutAutoresizingMaskConstraints

    /// The imageView that by default shows the up chevron image.
    open lazy var chevronImageView: UIImageView = .init()
        .withoutAutoresizingMaskConstraints

    /// The spacer that we control it's height in order to animate the lockView moving up or down
    /// when the user slides up/down their finger.
    open lazy var bottomPaddingSpacer: UIStackView = .init()
        .withoutAutoresizingMaskConstraints

    /// The constraint that is controlling the height of the `bottomPaddingSpacer` in order to move the
    /// lockView in relation to the user's vertical touch movement.
    open lazy var bottomPaddingConstraint: NSLayoutConstraint = bottomPaddingSpacer
        .heightAnchor
        .pin(equalToConstant: minimumBottomPadding)

    // MARK: - Configuration Properties

    /// The padding to add at the bottom when the content is `false`
    open var minimumBottomPadding: CGFloat = 4

    // MARK: - Lifecycle

    override open func setUp() {
        super.setUp()
        lockView.clipsToBounds = true
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(mainContainer, insets: .init(top: 0, leading: 4, bottom: 0, trailing: 4))
        mainContainer.addArrangedSubview(.spacer(axis: .horizontal).withoutAutoresizingMaskConstraints)
        mainContainer.addArrangedSubview(lockContainerStackView)

        lockContainerStackView.axis = .vertical
        lockContainerStackView.addArrangedSubview(lockView)
        lockContainerStackView.addArrangedSubview(bottomPaddingSpacer)

        lockView.embed(lockViewStackView, insets: .init(top: 8, leading: 8, bottom: 8, trailing: 8))

        lockViewStackView.axis = .vertical
        lockViewStackView.spacing = 8
        lockViewStackView.addArrangedSubview(lockImageView)
        lockViewStackView.addArrangedSubview(chevronImageView)

        bottomPaddingConstraint.isActive = true
    }

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = nil
        lockView.backgroundColor = theme.colors.outline

        lockImageView.image = theme.icons.lock
        chevronImageView.image = theme.icons.chevronUp

        lockImageView.tintColor = content ? theme.colors.primary : theme.colors.primaryLight
        chevronImageView.tintColor = lockImageView.tintColor
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        chevronImageView.isHidden = content
        chevronImageView.alpha = chevronImageView.isHidden ? 0 : 1

        bottomPaddingConstraint.constant = content
            ? minimumBottomPadding
            : bottomPaddingConstraint.constant

        setUpTheme()
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        lockView.layer.cornerRadius = lockContainerStackView.bounds.width / 2.0
    }
}
