//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

public
protocol ChannelConditionRequiredTableViewCellDelegate: AnyObject {
    func didTapGetTokenButton(in cell: ChannelConditionRequiredTableViewCell)
}

open
class ChannelConditionRequiredTableViewCell: _TableViewCell, UIProvider {
    open private(set) lazy var conditionLabel: UILabel = {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "condition_label")
    }()

    open private(set) lazy var getTokenButton: UIButton = {
        let button = UIButton()
        button.addTarget(self, action: #selector(getTokenButtonTapped), for: .touchUpInside)
        return button.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "get_token_button")
    }()

    open class var reuseId: String { String(describing: self) }
    open class var cellHeight: CGFloat {
        return 40
    }

    public
    var content: ChannelConditionPayload? {
        didSet {
            updateContentIfNeeded()
        }
    }

    weak var delegate: ChannelConditionRequiredTableViewCellDelegate?

    // MARK: - Life cycle

    open
    override func setUp() {
        getTokenButton.layer.cornerRadius = 4
        getTokenButton.setTitle(L10n.Channel.Invitation.getTokens, for: .normal)
    }

    open
    override func setUpUI() {
        super.setUpUI()
        contentView.addSubview(conditionLabel)
        conditionLabel.pin(anchors: [.top], to: contentView, contant: 8)
        conditionLabel.pin(anchors: [.centerY, .leading], to: contentView)
        contentView.addSubview(getTokenButton)
        getTokenButton.pin(anchors: [.top], to: contentView, contant: 8)
        getTokenButton.pin(anchors: [.centerY, .trailing], to: contentView)
        getTokenButton.leadingAnchor.pin(equalTo: conditionLabel.trailingAnchor, constant: 8).isActive = true
        getTokenButton.pin(anchors: [.width], to: 120)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        self.contentView.backgroundColor = theme.colors.surface

        conditionLabel.textColor = theme.colors.text
        conditionLabel.font = theme.fonts.body

        getTokenButton.setTitleColor(theme.colors.inverseOnSurface, for: .normal)
        getTokenButton.titleLabel?.font = theme.fonts.body
        getTokenButton.backgroundColor = theme.colors.text
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        guard let content else {
            conditionLabel.text = nil
            getTokenButton.isHidden = true
            return
        }
        getTokenButton.isHidden = false
        conditionLabel.text = "\(content.minimumBalance)" + " X " + content.tokenName
    }

    // MARK: - Action
    @objc
    func getTokenButtonTapped() {
        delegate?.didTapGetTokenButton(in: self)
    }
}

