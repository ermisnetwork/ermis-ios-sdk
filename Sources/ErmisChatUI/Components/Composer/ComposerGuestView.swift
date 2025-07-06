//
// Copyright 2025 Ermis Inc.
//

import UIKit

public
protocol ComposerGuestViewDelegate: AnyObject {
    func composerGuestViewDidSelectJoinChannel(in view: ComposerGuestView)
}

open
class ComposerGuestView: _View, ThemeProvider {
    open private(set) lazy var joinChannelLabel: UILabel = {
        UILabel().withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAccessibilityIdentifier(identifier: "joinChannelLabel")
    }()

    open private(set) lazy var joinChannelButton: UIButton = {
        let button = UIButton()
        button.setTitle(L10n.Composer.joinButton, for: .normal)
        button.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "joinChannelButton")
        return button
    }()

    public
    weak var delegate: ComposerGuestViewDelegate?

    // MARK: - Setup
    open
    override func setUp() {
        super.setUp()
        joinChannelButton.addTarget(self, action: #selector(joinChannelButtonDidTapped), for: .touchUpInside)
        joinChannelButton.layer.cornerRadius = 8
    }

    open
    override func setUpUI() {
        super.setUpUI()
        addSubview(joinChannelLabel)
        addSubview(joinChannelButton)

        joinChannelLabel.pin(anchors: [.top, .bottom], to: self, contant: 6)
        joinChannelLabel.pin(anchors: [.leading], to: self, contant: 16)

        joinChannelButton.pin(anchors: [.centerY], to: joinChannelLabel)
        joinChannelButton.leadingAnchor.pin(equalTo: joinChannelLabel.trailingAnchor, constant: 8).isActive = true
        joinChannelButton.pin(anchors: [.trailing], to: self, contant: -16)
        joinChannelButton.pin(anchors: [.height], to: 36)
        joinChannelButton.pin(anchors: [.width], to: 90)
    }

    open
    override func setUpTheme() {
        super.setUpTheme()
        backgroundColor = theme.colors.surface
        joinChannelLabel.font = theme.fonts.body
        joinChannelLabel.textColor = theme.colors.text

        joinChannelButton.setTitleColor(theme.colors.text, for: .normal)
        joinChannelButton.titleLabel?.font = theme.fonts.body
        joinChannelButton.backgroundColor = theme.colors.surfaceContainerLow
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        joinChannelLabel.text = L10n.Composer.joinChannelTitle
    }
    // MARK: - Action
    @objc
    func joinChannelButtonDidTapped() {
        delegate?.composerGuestViewDidSelectJoinChannel(in: self)
    }
}


