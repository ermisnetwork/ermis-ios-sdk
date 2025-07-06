//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The collection view of the suggestions view controller.
open class SuggestionsCollectionView: UICollectionView,
                                      UIProvider,
                                      BaseViewProtocol {
    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard superview != nil else { return }

        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    // MARK: - Init

    public required init(layout: UICollectionViewLayout) {
        super.init(frame: .zero, collectionViewLayout: layout)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Theme

    public func setUp() {}

    public func setUpTheme() {
        backgroundColor = theme.colors.surfaceContainer
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = true
        clipsToBounds = true
        layer.masksToBounds = true
        layer.cornerRadius = 10
    }

    public func setUpUI() {}

    public func contentDidChanged() {}
}
