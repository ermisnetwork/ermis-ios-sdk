//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

open class ChannelListLoadingViewCell: _TableViewCell, UIProvider {
    /// The `ChannelListLoadingViewCellContentView` instance used as content view.
    open private(set) lazy var channelListLoadingViewCellContentView: ChannelListLoadingViewCellContentView = components
        .channelListLoadingContentViewCell.init()
        .withoutAutoresizingMaskConstraints

    override open func setUp() {
        super.setUp()
        isUserInteractionEnabled = false
    }

    override open func setUpUI() {
        super.setUpUI()

        contentView.embed(channelListLoadingViewCellContentView)
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
    }
}
