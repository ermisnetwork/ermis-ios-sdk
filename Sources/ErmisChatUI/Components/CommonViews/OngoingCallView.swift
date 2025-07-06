//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class OngoingCallView: _View, ThemeProvider {
    public private(set) lazy var containerView = createContainerView()
    public private(set) lazy var imageView = createImageView()
    public private(set) lazy var titleLabel = createLabel()

    public var userInfo: [AnyHashable: Any]?

    public var callId: String? {
        return userInfo?["call_id"] as? String
    }

    open override func setUp() {
        super.setUp()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onBackgroundTapped)))
    }

    open override func setUpUI() {
        super.setUpUI()

        addSubviews([
            containerView
        ])

        containerView.pin(anchors: [.top], to: self, contant: 6)
        containerView.pin(anchors: [.centerX, .centerY], to: self)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        backgroundColor = theme.colors.success
        containerView.backgroundColor = theme.colors.success
        imageView.tintColor = theme.colors.onSuccess
        imageView.image = theme.icons.ongoingCall
        titleLabel.textColor = theme.colors.onSuccess
        titleLabel.font = theme.fonts.body
    }

    @objc private func onBackgroundTapped() {
        NotificationCenter.default.post(name: .ongoingCallViewDidTap, object: self, userInfo: userInfo)
    }
}

extension OngoingCallView {
    private func createContainerView() -> UIView {
        let view = ContainerStackView()
        view.axis = .horizontal
        view.spacing = 10
        view.alignment = .center
        view.addArrangedSubviews([
            imageView,
            titleLabel
        ])
        return view.withoutAutoresizingMaskConstraints
    }

    private func createImageView() -> UIImageView {
        let imageView = UIImageView()
        return imageView.withoutAutoresizingMaskConstraints
    }

    private func createLabel() -> UILabel {
        let label = UILabel()
        label.text = L10n.ChannelList.OngoingCall.tapToReturnCall
        return label.withoutAutoresizingMaskConstraints
    }
}

