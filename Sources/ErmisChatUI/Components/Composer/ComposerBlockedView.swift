//
// Copyright 2025 Ermis Inc.
//

import UIKit

public
protocol ComposerBlockedViewDelegate: AnyObject {
    func composerBlockedViewDidSelectUnblockUser(in view: ComposerBlockedView)
}

open
class ComposerBlockedView: _View, ThemeProvider {
    open private(set) lazy var blockUserLabel: UILabel = {
        UILabel().withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAccessibilityIdentifier(identifier: "blockUserLabel")
    }()

    open private(set) lazy var unBlockedButton: UIButton = {
        let button = UIButton()
        button.setTitle(L10n.Composer.UserBlocked.unblock, for: .normal)
        button.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "unBlockedButton")
        return button
    }()

    public
    weak var delegate: ComposerBlockedViewDelegate?

    public
    var content: String = "" {
        didSet {
            updateContentIfNeeded()
        }
    }

    // MARK: - Setup
    open
    override func setUp() {
        super.setUp()
        unBlockedButton.addTarget(self, action: #selector(unBlockedButtonTapped), for: .touchUpInside)
        unBlockedButton.layer.cornerRadius = 8
    }

    open
    override func setUpUI() {
        super.setUpUI()
        addSubview(blockUserLabel)
        addSubview(unBlockedButton)

        blockUserLabel.pin(anchors: [.top, .bottom], to: self, contant: 6)
        blockUserLabel.pin(anchors: [.leading], to: self, contant: 16)

        unBlockedButton.pin(anchors: [.centerY], to: blockUserLabel)
        unBlockedButton.leadingAnchor.pin(equalTo: blockUserLabel.trailingAnchor, constant: 8).isActive = true
        unBlockedButton.pin(anchors: [.trailing], to: self, contant: -16)
        unBlockedButton.pin(anchors: [.height], to: 36)
        unBlockedButton.pin(anchors: [.width], to: 90)
    }

    open
    override func setUpTheme() {
        super.setUpTheme()
        backgroundColor = theme.colors.surface
        blockUserLabel.font = theme.fonts.body
        blockUserLabel.textColor = theme.colors.text

        unBlockedButton.setTitleColor(theme.colors.text, for: .normal)
        unBlockedButton.titleLabel?.font = theme.fonts.body
        unBlockedButton.backgroundColor = theme.colors.surfaceContainerLow
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        blockUserLabel.text = L10n.Composer.UserBlocked.title(content)
    }
    // MARK: - Action
    @objc
    func unBlockedButtonTapped() {
        delegate?.composerBlockedViewDidSelectUnblockUser(in: self)
    }
}
