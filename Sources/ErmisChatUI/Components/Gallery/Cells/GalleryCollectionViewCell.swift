//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit
import ErmisSharedUI

/// `UICollectionViewCell` for a gallery item.
open class GalleryCollectionViewCell: _CollectionViewCell, UIScrollViewDelegate, SharedComponentsProvider, ComponentsProvider {
    /// Triggered when the scroll view is single tapped.
    open var didTapOnce: (() -> Void)?

    /// The cell content.
    open var content: AnyMessageAttachment? {
        didSet { updateContentIfNeeded() }
    }

    /// `UIScrollView` to enable zooming the content.
    public private(set) lazy var scrollView = UIScrollView()
        .withoutAutoresizingMaskConstraints

    override open func setUpTheme() {
        super.setUpTheme()

        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
    }

    override open func setUp() {
        super.setUp()

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5

        let doubleTapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTapOnScrollView)
        )
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGestureRecognizer)

        let singleTapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSingleTapOnScrollView)
        )
        singleTapGestureRecognizer.numberOfTapsRequired = 1
        singleTapGestureRecognizer.require(toFail: doubleTapGestureRecognizer)
        scrollView.addGestureRecognizer(singleTapGestureRecognizer)
    }

    override open func setUpUI() {
        super.setUpUI()

        contentView.embed(scrollView)
    }

    /// Triggered when scroll view is double tapped.
    @objc open func handleDoubleTapOnScrollView() {
        if scrollView.zoomScale != scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale / 2, animated: true)
        }
    }

    open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        nil
    }

    /// Triggered when scroll view is single tapped.
    @objc open func handleSingleTapOnScrollView() {
        didTapOnce?()
    }

    override open func prepareForReuse() {
        super.prepareForReuse()

        didTapOnce = nil
        content = nil
    }
}
