//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

public
protocol ChannelConditionRequiredAlertViewDelegate: AnyObject {
    func channelConditionRequiredAlertDidClose(_ alert: ChannelConditionRequiredView)
    func channelConditionRequiredAlertDidReCheck(_ alert: ChannelConditionRequiredView)
    func channelConditionRequiredAlert(_ alert: ChannelConditionRequiredView,
                                       didSelectGetTokensFor condition: ChannelConditionPayload)
}

open
class ChannelConditionRequiredView: _View, UIProvider {
    open private (set) lazy var closeButton: UIButton = components.closeButton.init()
        .withoutAutoresizingMaskConstraints

    open private (set) lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.multiline
        return label.withoutAutoresizingMaskConstraints
    }()

    open private (set) lazy var messageLabel: UILabel = {
        let label = UILabel()
        label.multiline
        return label.withoutAutoresizingMaskConstraints
    }()

    open private (set) lazy var tableView: UITableView = {
        let tableView = UITableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(components.channelConditionRequiredCell.self,
                           forCellReuseIdentifier: components.channelConditionRequiredCell.reuseId)
        tableView.separatorStyle = .none
        return tableView.withoutAutoresizingMaskConstraints
    }()

    open private (set) lazy var notEnoughTokenLabel: UILabel = {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
    }()

    open private (set) lazy var reCheckButton: UIButton = {
        let button = UIButton(type: .system)
        return button.withoutAutoresizingMaskConstraints
    }()

    var isLoading: Bool = false

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    weak var delegate: ChannelConditionRequiredAlertViewDelegate?

    var tableViewHeighConstraint: NSLayoutConstraint?

    // MARK: - BaseView protocol

    public
    override func setUp() {
        closeButton.addTarget(self, action: #selector(onCloseButtonDidTapped), for: .touchUpInside)
        reCheckButton.addTarget(self, action: #selector(onReCheckButtonDidTapped), for: .touchUpInside)
        reCheckButton.setTitle(L10n.Channel.Invitation.reCheck, for: .normal)
        reCheckButton.layer.cornerRadius = 4
    }

    public
    override func setUpUI() {
        [
            closeButton,
            titleLabel,
            messageLabel,
            tableView,
            notEnoughTokenLabel,
            reCheckButton
        ].forEach({
            self.addSubview($0)
        })

        closeButton.pin(anchors: [.top,.trailing], to: self)
        closeButton.pin(anchors: [.width, .height], to: 30)

        titleLabel.pin(anchors: [.top, .leading], to: self, contant: 32)
        titleLabel.pin(anchors: [.trailing], to: self, contant: -32)

        messageLabel.topAnchor.pin(equalTo: titleLabel.bottomAnchor, constant: 12).isActive = true
        messageLabel.pin(anchors: [.leading, .trailing], to: titleLabel)

        tableView.topAnchor.pin(equalTo: messageLabel.bottomAnchor).isActive = true
        tableView.pin(anchors: [.leading, .trailing], to: messageLabel)
        tableViewHeighConstraint = tableView.heightAnchor.constraint(equalToConstant: 0)
        tableViewHeighConstraint?.priority = .defaultHigh
        tableViewHeighConstraint?.isActive = true

        notEnoughTokenLabel.topAnchor.pin(equalTo: tableView.bottomAnchor).isActive = true
        notEnoughTokenLabel.pin(anchors: [.leading, .trailing], to: tableView)

        reCheckButton.topAnchor.pin(equalTo: notEnoughTokenLabel.bottomAnchor, constant: 0).isActive = true
        reCheckButton.pin(anchors: [.trailing], to: notEnoughTokenLabel)
        reCheckButton.pin(anchors: [.width], to: 100)
        reCheckButton.pin(anchors: [.bottom], to: self, contant: -32)
    }

    public
    override func setUpTheme() {
        titleLabel.textColor = theme.colors.text
        titleLabel.font = theme.fonts.title
        messageLabel.textColor = theme.colors.text
        messageLabel.font = theme.fonts.body
        notEnoughTokenLabel.textColor = theme.colors.error
        notEnoughTokenLabel.font = theme.fonts.body
        reCheckButton.setTitleColor(theme.colors.inverseOnSurface, for: .normal)
        reCheckButton.titleLabel?.font = theme.fonts.body
        reCheckButton.backgroundColor = theme.colors.text
    }

    public
    override func contentDidChanged() {
        guard let content = content else {
            return
        }

        titleLabel.text = L10n.Channel.Invitation.joinChannel(content.channel?.name)
        messageLabel.text = L10n.Channel.Invitation.directAccceptRequireMessage
        notEnoughTokenLabel.text = L10n.Channe.Invitation.notEnoughTokens
        tableViewHeighConstraint?.constant = CGFloat(content.channelConditions.count) * components.channelConditionRequiredCell.cellHeight
        tableView.reloadData()
    }

    // MARK: - Action

    @objc
    private func onCloseButtonDidTapped() {
        delegate?.channelConditionRequiredAlertDidClose(self)
    }

    @objc
    private func onReCheckButtonDidTapped() {
        guard !isLoading else {
            return
        }
        isLoading = true
        delegate?.channelConditionRequiredAlertDidReCheck(self)
    }
}
// MARK: - UITableViewDelegate + DataSource
extension ChannelConditionRequiredView: UITableViewDelegate, UITableViewDataSource {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return content?.channelConditions.count ?? 0
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        guard let cell = tableView.dequeueReusableCell(withIdentifier: components.channelConditionRequiredCell.reuseId,
                                                       for: indexPath) as? ChannelConditionRequiredTableViewCell else {
            fatalError("Could not load ChannelConditionRequiredTableViewCell")
        }
        cell.content = content?.channelConditions[indexPath.row]
        cell.delegate = self
        return cell
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return components.channelConditionRequiredCell.cellHeight
    }
}
// MARK: - ChannelConditionRequiredTableViewCellDelegate
extension ChannelConditionRequiredView: ChannelConditionRequiredTableViewCellDelegate {
    public func didTapGetTokenButton(in cell: ChannelConditionRequiredTableViewCell) {
        guard let indexPath = tableView.indexPath(for: cell),
              let condition = content?.channelConditions[safe: indexPath.row] else {
            return
        }
        delegate?.channelConditionRequiredAlert(self, didSelectGetTokensFor: condition)
    }
}

// MARK: - Content
public
extension ChannelConditionRequiredView {
    struct Content {
        var channel: Channel?
        var channelConditions: [ChannelConditionPayload]
    }
}
