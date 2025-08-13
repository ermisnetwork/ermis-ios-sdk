//
//  ChannelListLoadingViewCell.swift
//  ErmisChat
//
//  Created by Tú Đinh on 4/8/25.
//


//
// Copyright 2025 Ermis Inc.
//

import UIKit

open class TopicListLoadingViewCell: _TableViewCell, UIProvider {
    /// The `ChannelListLoadingViewCellContentView` instance used as content view.
    open private(set) lazy var topicListLoadingViewCellContentView: TopicListLoadingViewCellContentView = components
        .topicListLoadingContentViewCell.init()
        .withoutAutoresizingMaskConstraints

    override open func setUp() {
        super.setUp()
        isUserInteractionEnabled = false
    }

    override open func setUpUI() {
        super.setUpUI()

        contentView.addSubview(topicListLoadingViewCellContentView)
        topicListLoadingViewCellContentView.pin(to: contentView)
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        topicListLoadingViewCellContentView.layoutSubviews()
    }
}
