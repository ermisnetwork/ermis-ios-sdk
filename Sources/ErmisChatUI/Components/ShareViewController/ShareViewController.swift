//////
////// Copyright 2025 Ermis Inc.
//////
////
////import UIKit
////import Social
////import ErmisChat
////import UniformTypeIdentifiers
////
////
////open class ShareViewController: _ViewController, ChannelListControllerDelegate, UITableViewDelegate, UITableViewDataSource {
////
//    open private(set) lazy var loadingIndicator: UIActivityIndicatorView = {
//        return UIActivityIndicatorView(style: .large).withoutAutoresizingMaskConstraints
//
//    }()
//
//    /// The `UITableView` instance that displays channel list.
//    open private(set) lazy var tableView = createTableView()
//
//    /// The `AlertsRouter` instance responsible for presenting alerts.
////    open lazy var alertsRouter = components
////        .alertsRouter
////        .init(rootViewController: self)
//
//    /// The data of the channel list.
//    public private(set) var channels: [Channel] = [] {
//        didSet {
//            generateDisplayChannelList()
//            tableView.reloadData()
//            updateContentIfNeeded()
//        }
//    }
//
//    public private(set) var displayChannels: [Channel] = []
//
//    public private(set) var searchText: String?
//
//    public var message: ChatMessage?
//
//    public var debouncer = Debouncer(0.3, queue: .main)
//
//    /// The `ChannelListController` instance that provides channels data.
//    public var controller: ChannelListController?
//    public var messageController: MessageController?
//
//    private let searchController = UISearchController()
//
//    // MARK: - Setup
//    open override func setUp() {
//        title = L10n.Forward.title
//        controller?.delegate = self
//        navigationItem.searchController = searchController
//        searchController.delegate = self
//        searchController.searchResultsUpdater = self
//        navigationItem.hidesSearchBarWhenScrolling = false
//        getShareContent()
//    }
//
//    open override func setUpUI() {
//        view.embed(tableView)
//    }
//
//    open override func setUpTheme() {
////        view.backgroundColor = theme.colors.surface
////        tableView.backgroundColor = theme.colors.surface
//    }
//
//    open override func contentDidChanged() {
//
//    }
//    
//    public func initialize(with client: ErmisClient) {
//        guard let currentUserId = client.currentUserId else {
//            rejectShareRequest()
//            return
//        }
//        
//        
//        let channelListQuery: ChannelListQuery = .init(
//            filter: .joinedChannels(memberId: currentUserId,
//                                    projectId: client.projectId ?? ""),
//            sort: [
//                .init(key: .lastMessageAt),
//                .init(key: .updatedAt)
//            ]
//        )
//        controller = client.channelListController(query: channelListQuery)
//        controller?.synchronize()
//        reloadChannels()
//    }
//
//    func getShareContent() {
//        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
//            return
//        }
//        for provider in extensionItem.attachments ?? [] {
//            if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier as String) {
//                provider.loadItem(forTypeIdentifier: UTType.text.identifier as String, options: nil) { (item, error) in
//                    if let text = item as? String {
//                        print("Received text: \(text)")
//                        // Handle the text
//                    }
//                }
//            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier as String) {
//                provider.loadItem(forTypeIdentifier: UTType.url.identifier as String, options: nil) { (item, error) in
//                    if let url = item as? URL {
//                        print("Received URL: \(url)")
//                        // Handle the URL
//                    }
//                }
//            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier as String) {
//                provider.loadItem(forTypeIdentifier: UTType.image.identifier as String, options: nil) { (item, error) in
//                    if let image = item as? UIImage {
//                        print("Received image")
//                        // Handle the image
//                    } else if let url = item as? URL {
//                        print("URL: \(url)")
//                    }
//                }
//            }
//        }
//    }
//    // MARK: - Action
//    /// Updates the list view with the most updated channels.
//    open func reloadChannels(completion: (() -> Void)? = nil) {
//        channels = Array(controller?.channels ?? []).sorted(by: {
//            let lLastMessageAt = $0.lastMessageAt ?? $0.updatedAt ?? $0.createdAt
//            let rLastMessageAt = $1.lastMessageAt ?? $1.updatedAt ?? $0.createdAt
//            return lLastMessageAt > rLastMessageAt
//        })
//        tableView.reloadData()
//    }
//    // MARK: - ChannelListControllerDelegate
//
//    open func controllerWillChangeChannels(_ controller: ChannelListController) {
//        tableView.layoutIfNeeded()
//    }
//
//    open func controller(
//        _ controller: ChannelListController,
//        didChangeChannels changes: [ListChange<Channel>]
//    ) {
//
//    }
//
//    // MARK: - TableView
//    open func numberOfSections(in tableView: UITableView) -> Int {
//        return 1
//    }
//
//    open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
////        return displayChannels.count
////    }
////
////    open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
////        let cell = tableView.dequeueReusableCell(with: components.shareTableViewCell.self, for: indexPath)
////        cell.itemviewDelegate = self
////        let channel = displayChannels[indexPath.row]
////        let avatarContent = ChannelAvatarView.Content(from: channel)
////        let channelName = formatters.channelName.format(channel: channel,
////                                                        forCurrentUserId: controller?.client.currentUserId)
////        cell.content = .init(cid: channel.cid,
////                             avatarContent: avatarContent,
////                             channelDisplayName: channelName)
////        return cell
////    }
////
////    // MARK: - Helper
////
////    func generateDisplayChannelList() {
////        guard let searchText = searchText, !searchText.isEmpty else {
////            displayChannels = channels.filter {
////                $0.cid != message?.cid
////            }
////            return
////        }
////        let predicate = NSPredicate(format: "SELF CONTAINS[cd] %@", searchText)
////        displayChannels = channels.filter {
////            predicate.evaluate(with: $0.name) && $0.cid != message?.cid
////        }
////    }
////
////    public func rejectShareRequest() {
////        //alertsRouter.showInfoAlert()
////        extensionContext?.cancelRequest(withError: ClientError.UserNotLogin())
////    }
////}
////// MARK: - UISearchControllerDelegate
////extension ShareViewController: UISearchControllerDelegate, UISearchResultsUpdating {
////    public func updateSearchResults(for searchController: UISearchController) {
////        searchText = searchController.searchBar.text
////
////        debouncer.execute { [weak self] in
////            self?.generateDisplayChannelList()
////            self?.tableView.reloadData()
////            self?.updateContentIfNeeded()
////        }
////    }
////}
////// MARK: - ForwardinMessageItemViewDelegate
////extension ShareViewController: ShareItemViewDelegate {
////    public func shareItemViewDidTapSendButton(_ view: ShareItemView, cid: ChannelId?) {
////        //alertsRouter.showToast(title: "Feature not implemented")
////    }
////}
////
////extension ShareViewController {
////    private func createTableView() -> UITableView {
////        let tableView = UITableView()
////        tableView.register(components.shareTableViewCell.self)
////        tableView.rowHeight = UITableView.automaticDimension
////        tableView.separatorStyle = .none
////        tableView.backgroundColor = .systemBackground
////        tableView.showsVerticalScrollIndicator = false
////        tableView.dataSource = self
////        tableView.delegate = self
////        return tableView.withoutAutoresizingMaskConstraints
////    }
////}
////
////
////public extension ClientError {
////    public final class UserNotLogin: ClientError {}
////}
