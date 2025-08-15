//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Gallery view that displays images and video previews.
open class MessageGalleryView: _View, UIProvider {
    /// Content the gallery should display.
    public var content: [UIView] = [] {
        didSet { updateContentIfNeeded() }
    }

    public private(set) lazy var itemSpots = [
        UIView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "FirstItem"),
        UIView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "SecondItem"),
        UIView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "ThirdItem"),
        UIView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "FourthItem")
    ]

    /// Overlay to be displayed when `content` contains more items than the gallery can display.
    public private(set) lazy var moreItemsOverlay = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "MoreItems")

    /// Container holding all previews.
    public private(set) lazy var previewsContainerView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "previewsContainerView")

    /// Left container for previews.
    public private(set) lazy var topPreviewContainerView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "leftPreviewsContainerView")

    /// Right container for previews.
    public private(set) lazy var bottomPreviewContainerView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "rightPreviewsContainerView")

    // MARK: - Overrides

    override open func setUpUI() {
        super.setUpUI()

        previewsContainerView.axis = .vertical
        previewsContainerView.distribution = .equal
        previewsContainerView.alignment = .fill
        previewsContainerView.spacing = 2
        previewsContainerView.isLayoutMarginsRelativeArrangement = true
        previewsContainerView.directionalLayoutMargins = .zero
        embed(previewsContainerView)

        topPreviewContainerView.spacing = 2
        topPreviewContainerView.axis = .horizontal
        topPreviewContainerView.distribution = .equal
        topPreviewContainerView.alignment = .fill
        previewsContainerView.addArrangedSubview(topPreviewContainerView)

        topPreviewContainerView.addArrangedSubview(itemSpots[0])
        topPreviewContainerView.addArrangedSubview(itemSpots[1])

        bottomPreviewContainerView.spacing = 2
        bottomPreviewContainerView.axis = .horizontal
        bottomPreviewContainerView.distribution = .equal
        bottomPreviewContainerView.alignment = .fill
        previewsContainerView.addArrangedSubview(bottomPreviewContainerView)

        bottomPreviewContainerView.addArrangedSubview(itemSpots[2])
        bottomPreviewContainerView.addArrangedSubview(itemSpots[3])

        addSubview(moreItemsOverlay)
        moreItemsOverlay.pin(to: itemSpots[3])
    }

    override open func setUpTheme() {
        super.setUpTheme()
        self.backgroundColor = theme.colors.surface
        moreItemsOverlay.font = theme.fonts.title
        moreItemsOverlay.adjustsFontForContentSizeCategory = true
        moreItemsOverlay.textAlignment = .center
        moreItemsOverlay.textColor = theme.colors.white
        moreItemsOverlay.backgroundColor = theme.colors.surfaceContainerHigh.withAlphaComponent(0.4)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        // Clear all spots
        itemSpots
            .flatMap(\.subviews)
            .forEach { $0.removeFromSuperview() }

        guard !content.isEmpty else {
            isHidden = true
            return
        }

        isHidden = false

        // Add previews to the spots
        zip(itemSpots, content).forEach { $0.embed($1) }

        // Show taken spots, hide empty ones
        itemSpots.forEach { spot in
            spot.isHidden = spot.subviews.isEmpty
        }

        bottomPreviewContainerView.isHidden = bottomPreviewContainerView.subviews
            .allSatisfy(\.isHidden)
        topPreviewContainerView.isHidden = topPreviewContainerView.subviews
            .allSatisfy(\.isHidden)
        previewsContainerView.isHidden = previewsContainerView.subviews
            .allSatisfy(\.isHidden)

        let notShownPreviewsCount = content.count - itemSpots.count
        moreItemsOverlay.text = notShownPreviewsCount > 0 ? "+\(notShownPreviewsCount)" : nil
        moreItemsOverlay.isHidden = moreItemsOverlay.text == nil
    }
}
