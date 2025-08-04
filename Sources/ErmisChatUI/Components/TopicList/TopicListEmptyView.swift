//
//  ChannelListEmptyView.swift
//  ErmisChat
//
//  Created by Tú Đinh on 4/8/25.
//


//
// Copyright 2025 Ermis Inc.
//

import UIKit

open class TopicListEmptyView: _View, UIProvider {
    /// Container which holds all elements except action button in this view.
    open private(set) lazy var container: ContainerStackView = ContainerStackView().withoutAutoresizingMaskConstraints
    /// Icon ImageView which is displayed above the title label.
    open private(set) lazy var iconView: UIImageView = UIImageView().withoutAutoresizingMaskConstraints
    /// Title label which displays the main message for the empty view.
    open private(set) lazy var titleLabel: UILabel = UILabel().withoutAutoresizingMaskConstraints
    /// Subtitle label which displays additional information for the empty view.
    open private(set) lazy var subtitleLabel: UILabel = UILabel().withoutAutoresizingMaskConstraints
    /// Button for an additional action on the empty view. E.g. start a new chat.
    open private(set) lazy var actionButton: UIButton = UIButton(type: .system).withoutAutoresizingMaskConstraints

    public var actionButtonPressed: (() -> Void)?

    override open func setUp() {
        super.setUp()

        titleLabel.text = L10n.ChannelList.Empty.title
        subtitleLabel.text = L10n.ChannelList.Empty.subtitle
        actionButton.setTitle(L10n.ChannelList.Empty.button, for: .normal)
        actionButton.addTarget(self, action: #selector(didTapActionButton), for: .touchUpInside)
    }

    override open func setUpUI() {
        super.setUpUI()

        directionalLayoutMargins = .init(top: 8, leading: 32, bottom: 8, trailing: 32)

        addSubview(container)
        container.pin(anchors: [.centerX, .centerY], to: self)
        container.pin(anchors: [.leading, .trailing], to: layoutMarginsGuide)
        container.axis = .vertical
        container.alignment = .center
        container.addArrangedSubviews([iconView, titleLabel, subtitleLabel])

        addSubview(actionButton)
        NSLayoutConstraint.activate([
            actionButton.centerXAnchor.pin(equalTo: container.centerXAnchor),
            actionButton.topAnchor.pin(equalTo: container.bottomAnchor, constant: 32),
            actionButton.bottomAnchor.pin(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor),
            actionButton.heightAnchor.pin(greaterThanOrEqualToConstant: 52),
            actionButton.widthAnchor.pin(greaterThanOrEqualToConstant: 240)
        ])
        actionButton.layer.cornerRadius = 12
    }

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = theme.colors.surface

        titleLabel.font = theme.fonts.headline.bold
        titleLabel.textColor = theme.colors.text
        titleLabel.textAlignment = .center

        subtitleLabel.font = theme.fonts.body
        subtitleLabel.textColor = theme.colors.subtitleText
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center

        actionButton.titleLabel?.font = theme.fonts.body.bold
        actionButton.setTitleColor(theme.colors.onPrimary, for: .normal)
        actionButton.backgroundColor = theme.colors.primary
    }

    @objc open func didTapActionButton() {
        actionButtonPressed?()
    }
}
