//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

open class ForwardingMessageViewController: _ViewController, UIProvider, ChannelListControllerDelegate, UITableViewDelegate, UITableViewDataSource {

    open private(set) lazy var loadingIndicator: UIActivityIndicatorView = {
        return UIActivityIndicatorView(style: .large).withoutAutoresizingMaskConstraints

    }()

    /// The `UITableView` instance that displays channel list.
    open private(set) lazy var tableView = createTableView()

    /// The `AlertsRouter` instance responsible for presenting alerts.
    open lazy var alertsRouter = components
        .alertsRouter
        .init(rootViewController: self)

    /// The data of the channel list.
    public private(set) var channels: [Channel] = [] {
        didSet {
            generateDisplayChannelList()
            tableView.reloadData()
            updateContentIfNeeded()
        }
    }

    public private(set) var displayChannels: [Channel] = []

    public private(set) var searchText: String?

    public var message: ChatMessage?

    public var debouncer = Debouncer(0.3, queue: .main)

    /// The `ChannelListController` instance that provides channels data.
    public var controller: ChannelListController?
    public var messageController: MessageController?

    open var collectionViewCellReuseIdentifier: String { String(describing: ForwardingMessageCell.self) }

    private var forwardStates: [ChannelId: ForwardingState] = [:]
    private let forwardStateUpdatingQueue = DispatchQueue(label: "forwardStateUpdatingQueue")
    private let searchController = UISearchController()
    // MARK: - Setup
    open override func setUp() {
        title = L10n.Forward.title
        controller?.delegate = self
        controller?.synchronize()
        reloadChannels()
        navigationItem.searchController = searchController
        searchController.delegate = self
        searchController.searchResultsUpdater = self
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    open override func setUpUI() {
        view.embed(tableView)
    }

    open override func setUpTheme() {
        view.backgroundColor = theme.colors.surface
        tableView.backgroundColor = theme.colors.surface
    }

    open override func contentDidChanged() {

    }

    // MARK: - Action
    /// Updates the list view with the most updated channels.
    open func reloadChannels(completion: (() -> Void)? = nil) {
        channels = Array(controller?.channels ?? []).sorted(by: {
            let lLastMessageAt = $0.lastMessageAt ?? $0.updatedAt ?? $0.createdAt
            let rLastMessageAt = $1.lastMessageAt ?? $1.updatedAt ?? $0.createdAt
            return lLastMessageAt > rLastMessageAt
        })
        tableView.reloadData()
    }
    // MARK: - ChannelListControllerDelegate

    open func controllerWillChangeChannels(_ controller: ChannelListController) {
        tableView.layoutIfNeeded()
    }

    open func controller(
        _ controller: ChannelListController,
        didChangeChannels changes: [ListChange<Channel>]
    ) {
        tableView.reloadData()
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        switch state {
        case .localDataFetched:
            tableView.reloadData()
        case .remoteDataFetched:
            tableView.reloadData()
        default:
            break
        }
    }

    // MARK: - TableView
    open func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayChannels.count
    }

    open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(with: components.forwardingMessageCell.self, for: indexPath)
        cell.itemviewDelegate = self
        let channel = displayChannels[indexPath.row]
        cell.content = .init(channel: channel, forwardingState: forwardingState(of: channel))
        return cell
    }

    // MARK: - Helper
    func forwardingState(of channel: Channel) -> ForwardingState {
        if let state = forwardStates[channel.cid] {
            return state
        } else {
            setForwardingState(.idle, for: channel)
            return .idle
        }
    }

    func setForwardingState(_ state: ForwardingState, for channel: Channel) {
        forwardStateUpdatingQueue.sync {
            forwardStates[channel.cid] = state

            DispatchQueue.main.async {
                if let index = self.displayChannels.firstIndex(where: { $0.cid == channel.cid }),
                   let cell = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? ForwardingMessageCell {
                    cell.content = .init(channel: channel, forwardingState: state)
                }
            }
        }
    }

    func generateDisplayChannelList() {
        guard let searchText = searchText, !searchText.isEmpty else {
            displayChannels = channels.filter {
                $0.cid != message?.cid
            }
            return
        }
        let predicate = NSPredicate(format: "SELF CONTAINS[cd] %@", searchText)
        displayChannels = channels.filter {
            predicate.evaluate(with: $0.name) && $0.cid != message?.cid
        }
    }
}
// MARK: - UISearchControllerDelegate
extension ForwardingMessageViewController: UISearchControllerDelegate, UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text

        debouncer.execute { [weak self] in
            self?.generateDisplayChannelList()
            self?.tableView.reloadData()
            self?.updateContentIfNeeded()
        }
    }
}
// MARK: - ForwardinMessageItemViewDelegate
extension ForwardingMessageViewController: ForwardingMessageItemViewDelegate {
    public func forwardingMessageItemViewDidTapSendButton(_ view: ForwardingMessageItemView, cid: ChannelId?) {
        guard let message, let channel = channels.first(where: { $0.cid == cid }) else {
            return
        }
        setForwardingState(.forwarding, for: channel)
        messageController?.forward(message: message, to: channel.cid) { [weak self] error in
            if let error = error {
                log.error("Forwarding message failed: \(error)")
                self?.setForwardingState(.error, for: channel)
                self?.alertsRouter.showMessageForwardingAlert(false)
            } else {
                self?.setForwardingState(.forwarded, for: channel)
                self?.alertsRouter.showMessageForwardingAlert(true)
            }
        }
    }
}

extension ForwardingMessageViewController {
    private func createTableView() -> UITableView {
        let tableView = UITableView()
        tableView.register(components.forwardingMessageCell.self)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        return tableView.withoutAutoresizingMaskConstraints
    }
}

public extension ForwardingMessageViewController {
    enum ForwardingState {
        case idle
        case forwarding
        case forwarded
        case error
    }
}
