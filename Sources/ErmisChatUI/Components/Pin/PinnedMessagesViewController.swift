//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol PinnedMessageViewControllerDelegate: AnyObject {
    func pinnedMessageViewController(_ pinnedMessageViewController: PinnedMessagesViewController, didSelected pinnedMessage: ChatMessage)
}


open class PinnedMessagesViewController: _ViewController, UIProvider {
    public private(set) lazy var tableView = createTableView()

    open lazy var alertsRouter = components
        .alertsRouter
    // Temporary solution until the actions router works with with the `UIWindow`
        .init(rootViewController: self.parent ?? self)

    public var channelController: ChannelController? {
        didSet {
            updateContentIfNeeded()
            channelController?.delegate = self
        }
    }

    public var channel: Channel? {
        return channelController?.channel
    }

    public var client: ErmisClient? {
        return channelController?.client
    }

    private var messageController: MessageController?

    public weak var delegate: PinnedMessageViewControllerDelegate?

    var pinnedMessages: [ChatMessage] {
        return (channel?.pinnedMessages ?? [])
    }
    // MARK: - Setup
    open override func setUp() {
        tableView.reloadData()
        self.title = "Pinned Messages"
    }

    open override func setUpUI() {
        view.addSubview(tableView)
        view.embed(tableView)
    }

    open override func setUpTheme() {
        view.backgroundColor = theme.colors.surface
        tableView.backgroundColor = theme.colors.surface
    }

    open override func contentDidChanged() {
        tableView.reloadData()
    }

    open func close() {
        navigationController?.popViewController(animated: true)
    }
}
// MARK: - PinnedMessagesViewController
extension PinnedMessagesViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pinnedMessages.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(with: components.pinnedMessageCell, for: indexPath)
        if let channel = channel {
            let message = pinnedMessages[indexPath.row]
            cell.content = .init(message: message, channel: channel)
        } else {
            cell.content = nil
        }
        cell.delegate = self
        return cell
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        close()
        delegate?.pinnedMessageViewController(self, didSelected: pinnedMessages[indexPath.row])
    }
}
// MARK: - CreateUI
extension PinnedMessagesViewController {
    private func createTableView() -> UITableView {
        let tableView = UITableView()
        tableView.register(components.pinnedMessageCell)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        return tableView.withoutAutoresizingMaskConstraints
    }
}
// MARK: - PinnedMessageCellDelegate
extension PinnedMessagesViewController: PinnedMessageCellDelegate {
    public func pinnedMessageCell(_ cell: PinnedMessageCell, didSelectShowInChat message: ChatMessage) {
        close()
        delegate?.pinnedMessageViewController(self, didSelected: message)
    }

    public func pinnedMessageCell(_ cell: PinnedMessageCell, didSelectedUnPin message: ChatMessage) {
        self.alertsRouter.showMessageUnpinConfirmationAlert { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard let client, let cid = channel?.cid else { return }
            messageController = client.messageController(cid: cid, messageId: message.id)

            messageController?.unpin { [weak self] error in
                guard let self else { return }
                if let error {
                    self.alertsRouter.showMessageUnpinResultAlert(false)
                    return
                }
                self.alertsRouter.showMessageUnpinResultAlert(true)

            }
        }
    }
}
// MARK: - ChannelControllerDelegate
extension PinnedMessagesViewController: ChannelControllerDelegate {
    public func channelController(_ channelController: ChannelController, didUpdateMessages changes: [ListChange<ChatMessage>]) {
        updateContentIfNeeded()
    }

    public func channelController(_ channelController: ChannelController, didUpdateChannel channel: EntityChange<Channel>) {
        updateContentIfNeeded()
    }
}
