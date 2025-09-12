//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import ErmisChat

public protocol TopicClosedViewDelegate: AnyObject {
    func topicClosedViewDidTapReOpenTopicButton(_ view: TopicClosedView)
}

open class TopicClosedView: _View, UIProvider {
    open private(set) lazy var containerView = createContainerView()
    open private(set) lazy var titleLabel = createTitleLabel()

    open private(set) lazy var reOpenTopicButton = createReOpenTopicButton()

    public weak var delegate: TopicClosedViewDelegate?

    public var canReopenTopic: Bool = false {
        didSet {
            updateContentIfNeeded()
        }
    }

    public var isEnable: Bool = true

    // MARK: - _View
    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        addSubview(containerView)
        containerView.pin(anchors: [.top], to: self, contant: 8)
        containerView.pin(anchors: [.leading], to: self, contant: 16)
        containerView.pin(anchors: [.centerX, .centerY], to: self)
        containerView.addArrangedSubviews([titleLabel, reOpenTopicButton])
        reOpenTopicButton.pin(anchors: [.height], to: 52)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        backgroundColor = .clear
        titleLabel.font = theme.fonts.callout.semiBold
        titleLabel.textColor = theme.colors.error
        var configuration = reOpenTopicButton.configuration
        configuration?.background.cornerRadius = 15
        configuration?.background.backgroundColor = theme.colors.white
        configuration?.baseForegroundColor = theme.colors.text
        configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] incoming in
            guard let self else { return incoming }
            var outgoing = incoming
            outgoing.font = self.theme.fonts.callout.semiBold
            return outgoing
        }
        reOpenTopicButton.configuration = configuration
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        titleLabel.isHidden = canReopenTopic
        reOpenTopicButton.isHidden = !canReopenTopic
    }

    // MARK: - Action
    @objc private func reOpenTopicButtonTapped() {
        guard isEnable else {
            return
        }
        delegate?.topicClosedViewDidTapReOpenTopicButton(self)
    }
    // MARK: - Create UI
    open func createContainerView() -> ContainerStackView {
        let container = ContainerStackView().withoutAutoresizingMaskConstraints
        container.axis = .vertical
        container.alignment = .fill
        container.distribution = .natural
        return container
    }

    open func createTitleLabel() -> UILabel {
        let label = UILabel()
            .withoutAutoresizingMaskConstraints
            .withAdjustingFontForContentSizeCategory
            .centerTextAlignment
            .withAccessibilityIdentifier(identifier: "titleLabel")
        label.text = L10n.Topic.closed
        return label
    }

    open func createReOpenTopicButton() -> UIButton {
        let button = UIButton().withoutAutoresizingMaskConstraints
        var configuration = button.configuration ?? .plain()
        configuration.title = L10n.Topic.closed
        configuration.image = theme.icons.topicOpen
        configuration.imagePadding = 12
        button.configuration = configuration
        button.addTarget(self, action: #selector(reOpenTopicButtonTapped), for: .touchUpInside)
        return button
    }


}
