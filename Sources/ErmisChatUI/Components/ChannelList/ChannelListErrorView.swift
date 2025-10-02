//
// Copyright 2025 Ermis Inc.
//

import UIKit

open class ChannelListErrorView: _View, UIProvider {
    /// Container which holds the elements on the error banner.
    open private(set) lazy var container: ContainerStackView = ContainerStackView().withoutAutoresizingMaskConstraints
    /// Label describing there has been an error.
    open private(set) lazy var titleLabel: UILabel = UILabel().centerTextAlignment.withBidirectionalLanguagesSupport.withoutAutoresizingMaskConstraints
    /// Retry button which is located at the trailing of the view.
    open private(set) lazy var retryButton: UIButton = UIButton().withoutAutoresizingMaskConstraints
    /// Spacing view so the button has some spacing with bidirectional language support.
    open private(set) lazy var spacer: UIView = UIView().withoutAutoresizingMaskConstraints

    open var refreshButtonAction: (() -> Void)?

    /// Value of `channelListErrorView` height constraint.
    open var channelListErrorViewHeight: CGFloat { 88 }

    override open func setUp() {
        super.setUp()

        titleLabel.text = L10n.ChannelList.Error.message
        retryButton.addTarget(self, action: #selector(didTapRetryButton), for: .touchUpInside)
    }

    override open func setUpTheme() {
        super.setUpTheme()
        retryButton.setImage(theme.icons.restart, for: .normal)
        backgroundColor = theme.colors.surfaceContainer
        titleLabel.textColor = theme.colors.onSurface
        retryButton.tintColor = theme.colors.onSurface
    }

    override open func setUpUI() {
        super.setUpUI()

        heightAnchor.pin(greaterThanOrEqualToConstant: channelListErrorViewHeight).isActive = true
        directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        addSubview(container)
        container.pin(anchors: [.leading, .trailing, .top], to: layoutMarginsGuide)
        container.bottomAnchor.pin(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor).isActive = true
        container.axis = .vertical
        container.alignment = .center
        container.addArrangedSubviews([titleLabel, retryButton])
    }

    @objc open func didTapRetryButton() {
        refreshButtonAction?()
    }

    /// Shows the error view.
    open func show() {
        center = .init(x: center.x, y: center.y + channelListErrorViewHeight)
        isHidden = false

        UIView.animate(withDuration: 0.5) {
            self.center = .init(x: self.center.x, y: self.center.y - self.channelListErrorViewHeight)
            self.layoutSubviews()
        }
    }

    /// Hides the error view.
    open func hide() {
        if isHidden { return }
        UIView.animate(withDuration: 0.5) {
            self.center = .init(x: self.center.x, y: self.center.y + self.channelListErrorViewHeight)
            self.layoutSubviews()
        } completion: { _ in
            self.isHidden = true
        }
    }
}
