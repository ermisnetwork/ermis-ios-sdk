//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// `UICollectionView` subclass which embeds inside `MessageComposerMentionCellView`
open class MentionSuggestionCollectionViewCell: _CollectionViewCell, ComponentsProvider {
    /// Reuse identifier for the cell used in `collectionView(cellForItem:)`
    open class var reuseId: String { String(describing: self) }

    /// Instance of `MessageComposerMentionCellView` which shows information about the mentioned user.
    open lazy var mentionView: MentionSuggestionView = components
        .suggestionsMentionView.init()
        .withoutAutoresizingMaskConstraints

    override open func setUpUI() {
        super.setUpUI()
        contentView.embed(mentionView)
    }

    // We need this method for `UICollectionViewCells` resize properly inside collectionView
    // and respect collectionView width. Without this method, the collectionViewCell content
    // autoresizes itself and ignores bounds of parent collectionView
    override open func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let preferredAttributes = super.preferredLayoutAttributesFitting(layoutAttributes)

        let targetSize = CGSize(
            width: layoutAttributes.frame.width,
            height: UIView.layoutFittingCompressedSize.height
        )

        preferredAttributes.frame.size = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        return preferredAttributes
    }
}
