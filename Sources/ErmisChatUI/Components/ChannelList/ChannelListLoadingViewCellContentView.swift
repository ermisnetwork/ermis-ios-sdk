//
// Copyright 2025 Ermis Inc.
//

import UIKit

/// The view of the `ChannelListLoadingViewCell`, which contains the UI elements being animated with a shimmer.
open class ChannelListLoadingViewCellContentView: _View, UIProvider, SkeletonLoadable {
    open private(set) lazy var avatarView: UIView = UIView()
        .withoutAutoresizingMaskConstraints

    open private(set) lazy var topView = UIView()
        .withoutAutoresizingMaskConstraints

    open private(set) lazy var bottomView = UIView()
        .withoutAutoresizingMaskConstraints

    private let avatarViewLayer = CAGradientLayer()
    private let topLayer = CAGradientLayer()
    private let bottomLayer = CAGradientLayer()

    override open func setUp() {
        super.setUp()
        avatarViewLayer.startPoint = CGPoint(x: 0, y: 0.5)
        avatarViewLayer.endPoint = CGPoint(x: 1, y: 0.5)
        avatarView.layer.addSublayer(avatarViewLayer)

        topLayer.startPoint = CGPoint(x: 0, y: 0.5)
        topLayer.endPoint = CGPoint(x: 1, y: 0.5)
        topView.layer.addSublayer(topLayer)

        bottomLayer.startPoint = CGPoint(x: 0, y: 0.5)
        bottomLayer.endPoint = CGPoint(x: 1, y: 0.5)
        bottomView.layer.addSublayer(bottomLayer)

        let avatarGroup = makeAnimationGroup()
        avatarGroup.beginTime = 0.0
        avatarViewLayer.add(avatarGroup, forKey: "backgroundColor")

        let topGroup = makeAnimationGroup(previousGroup: avatarGroup)
        topLayer.add(topGroup, forKey: "backgroundColor")

        let bottomGroup = makeAnimationGroup(previousGroup: avatarGroup)
        bottomLayer.add(bottomGroup, forKey: "backgroundColor")
    }

    override open func setUpUI() {
        super.setUpUI()
        addSubviews([
            avatarView, topView, bottomView
        ])

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.pin(equalTo: self.leadingAnchor, constant: 16),
            avatarView.widthAnchor.pin(equalToConstant: 56),
            avatarView.heightAnchor.pin(equalToConstant: 56),
            avatarView.centerYAnchor.pin(equalTo: self.centerYAnchor),
            topView.leadingAnchor.pin(equalTo: avatarView.trailingAnchor, constant: 8),
            topView.topAnchor.pin(equalTo: avatarView.topAnchor),
            topView.trailingAnchor.pin(equalTo: self.trailingAnchor, constant: -16),
            topView.heightAnchor.pin(equalToConstant: 28),
            bottomView.leadingAnchor.pin(equalTo: topView.leadingAnchor),
            bottomView.topAnchor.pin(equalTo: topView.bottomAnchor, constant: 4),
            bottomView.trailingAnchor.pin(equalTo: topView.trailingAnchor),
            bottomView.bottomAnchor.pin(equalTo: self.bottomAnchor, constant: -8),
            bottomView.heightAnchor.pin(equalTo: topView.heightAnchor)
        ])

        avatarViewLayer.cornerRadius = 20
        topLayer.cornerRadius = 14
        bottomLayer.cornerRadius = 14
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        if avatarViewLayer.frame != avatarView.bounds {
            avatarViewLayer.frame = avatarView.bounds
        }

        if topLayer.frame != topView.bounds {
            topLayer.frame = topView.bounds
        }

        if bottomLayer.frame != bottomView.bounds {
            bottomLayer.frame = bottomView.bounds
        }
    }
}
