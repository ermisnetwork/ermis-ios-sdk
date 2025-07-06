//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit

/// A `UICollectionViewCell` subclass that shows channel information.
open class ContactListCollectionViewCell: _CollectionViewCell,
                                          UIProvider {
    /// The `ChannelListItemView` instance used as content view.
    open private(set) lazy var itemView: ContactListItemView = components
        .contactListContentView
        .init()
        .withoutAutoresizingMaskConstraints

    override public func prepareForReuse() {
        super.prepareForReuse()
        itemView.content = nil
    }

    override open var isSelected: Bool {
        didSet {
            itemView.backgroundColor = isSelected
            ? itemView.contentHighlightedBackgroundColor
            : itemView.contentBackgroundColor
        }
    }

    override open var isHighlighted: Bool {
        didSet {
            itemView.backgroundColor = isHighlighted
            ? itemView.contentHighlightedBackgroundColor
            : itemView.contentBackgroundColor
        }
    }

    override open func setUp() {
        super.setUp()
    }

    override open func setUpUI() {
        super.setUpUI()

        contentView.addSubview(itemView)
        NSLayoutConstraint.activate([
            itemView.widthAnchor.pin(equalTo: contentView.widthAnchor),
            itemView.topAnchor.pin(equalTo: contentView.topAnchor),
            itemView.trailingAnchor.pin(equalTo: contentView.trailingAnchor),
            itemView.bottomAnchor.pin(equalTo: contentView.bottomAnchor)
        ])
    }

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

