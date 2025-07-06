//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

/// A container view that clamps its size to the size of the bigger subview, even when this subview is hidden.
open class ClampedView: _View, ThemeProvider {
    // MARK: - UI Components

    open private(set) lazy var container: UIStackView = .init()
        .withoutAutoresizingMaskConstraints

    // MARK: - Configuration Properties

    open var axis: NSLayoutConstraint.Axis = .horizontal {
        didSet { container.axis = axis }
    }

    // MARK: - Lifecycle

    override open func setUp() {
        super.setUp()
        container.axis = axis
        container.alignment = .center
    }

    override open func setUpUI() {
        super.setUpUI()
        embed(container, insets: .zero)
    }

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = nil
    }

    override open var intrinsicContentSize: CGSize {
        let maxSize = CGSize(width: 0, height: bounds.height)

        let newSize = container.arrangedSubviews.reduce(maxSize) { partialResult, subview in
            let subviewSize = subview.sizeThatFits(bounds.size)
            return CGSize(width: max(partialResult.width, subviewSize.width), height: max(subviewSize.height, partialResult.height))
        }

        return newSize
    }

    // MARK: - Subviews

    open func addArrangedSubview(_ view: UIView) {
        container.addArrangedSubview(view.withoutAutoresizingMaskConstraints)
    }
}
