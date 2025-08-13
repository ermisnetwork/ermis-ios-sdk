//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import Social
import ErmisChat
import UniformTypeIdentifiers


open class ShareViewController: _ViewController, UIProvider, ChannelListControllerDelegate, UITableViewDelegate, UITableViewDataSource {

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

    public var content = Content()
    public var message: ChatMessage?

    public var channelController: ChannelController?

    public var debouncer = Debouncer(0.3, queue: .main)

    /// The `ChannelListController` instance that provides channels data.
    public var controller: ChannelListController?
    public var messageController: MessageController?

    private let searchController = UISearchController()

    private var hasFinishedLoadingItems: Bool = false

    /// The `OperationQueue` which handling incoming requests
    private let operationQueue: OperationQueue = {
        let operationQueue = OperationQueue(maxConcurrentCount: 3)
        operationQueue.name = "network.ermis.load-shared-content"
        operationQueue.qualityOfService = .userInitiated
        return operationQueue
    }()

    // MARK: - Setup
    open override func setUp() {
        title = L10n.Share.sendTo
        controller?.delegate = self
        navigationItem.searchController = searchController
        searchController.delegate = self
        searchController.searchResultsUpdater = self
        navigationItem.hidesSearchBarWhenScrolling = false
        getShareContent()
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
    
    public func initialize(with client: ErmisClient) {
        guard let currentUserId = client.currentUserId else {
            rejectShareRequest()
            return
        }
        
        
        let channelListQuery: ChannelListQuery = .init(
            filter: .joinedChannels(memberId: currentUserId,
                                    projectId: client.projectId ?? ""),
            sort: [
                .init(key: .default),
            ]
        )
        controller = client.channelListController(query: channelListQuery)
        controller?.synchronize()
        reloadChannels()
    }

    func getShareContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            return
        }
        for provider in extensionItem.attachments ?? [] {
            let operation = AttachmentLoadOperation(provider: provider) { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let content):
                    if let text = content.0 {
                        self.content.text.append(text)
                    } else if let attachment = content.1 {
                        self.content.attachments.append(attachment)
                    }
                case .failure(let failure):
                    break
                }
            }

            operationQueue.addOperation(operation)
        }

        operationQueue.addBarrierBlock { [weak self] in
            self?.hasFinishedLoadingItems = true
        }
    }
    // MARK: - Action
    /// Updates the list view with the most updated channels.
    open func reloadChannels(completion: (() -> Void)? = nil) {
        channels = Array(controller?.channels ?? [])
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

    }

    // MARK: - TableView
    open func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return displayChannels.count
    }

    open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(with: components.shareTableViewCell.self, for: indexPath)
        cell.itemviewDelegate = self
        let channel = displayChannels[indexPath.row]
        let avatarContent = ChannelAvatarView.Content(from: channel)
        let channelName = formatters.channelName.format(channel: channel,
                                                        forCurrentUserId: controller?.client.currentUserId)
        cell.content = .init(cid: channel.cid,
                             avatarContent: avatarContent,
                             channelDisplayName: channelName)
        return cell
    }

    // MARK: - Helper
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

    public func rejectShareRequest() {
        //alertsRouter.showInfoAlert()
        extensionContext?.cancelRequest(withError: ClientError.UserNotLogin())
    }
}
// MARK: - UISearchControllerDelegate
extension ShareViewController: UISearchControllerDelegate, UISearchResultsUpdating {
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
extension ShareViewController: ShareItemViewDelegate {
    public func shareItemViewDidTapSendButton(_ view: ShareItemView, cid: ChannelId?) {
        alertsRouter.showToast(title: "Feature not implemented")
//        guard let cid, let client = controller?.client else {
//            return
//        }
//        channelController = client.channelController(for: cid)
//        channelController?.synchronize()
//        channelController?.createNewMessage(text: "TEST SHARE !")
    }
}

extension ShareViewController {
    private func createTableView() -> UITableView {
        let tableView = UITableView()
        tableView.register(components.shareTableViewCell.self)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        return tableView.withoutAutoresizingMaskConstraints
    }
}

public extension ShareViewController {
    public struct Content {
        /// The text of the input text view.
        public var text: String
        /// The attachments of the message.
        public var attachments: [AnyAttachmentPayload]
        /// The mentioned users in the message.
        public var mentionedUsers: Set<ChatUser>
        /// A boolean that check is mention all in the message.
        public var hasMentionedAll: Bool

        public init() {
            text = ""
            attachments = []
            mentionedUsers = []
            hasMentionedAll = false
        }
    }
}

public extension ClientError {
    public final class UserNotLogin: ClientError {}
}

class AttachmentLoadOperation: Foundation.Operation, @unchecked Sendable {
    private let provider: NSItemProvider
    private let typeIdentifier: String
    private let completion: (Result<(String?, AnyAttachmentPayload?), Error>) -> Void

    // KVO state
    private var _executing = false
    override var isExecuting: Bool {
        get { _executing }
        set {
            willChangeValue(for: \.isExecuting)
            _executing = newValue
            didChangeValue(for: \.isExecuting)
        }
    }

    private var _finished = false
    override var isFinished: Bool {
        get { _finished }
        set {
            willChangeValue(for: \.isFinished)
            _finished = newValue
            didChangeValue(for: \.isFinished)
        }
    }

    init(provider: NSItemProvider, completion: @escaping (Result<(String?, AnyAttachmentPayload?), Error>) -> Void) {
        self.provider = provider
        self.completion = completion

        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            self.typeIdentifier = UTType.text.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            self.typeIdentifier = UTType.image.identifier
        } else {
            self.typeIdentifier = UTType.content.identifier
        }
        super.init()
    }

    override var isAsynchronous: Bool { true }

    override func start() {
        if isCancelled {
            finish()
            return
        }

        isExecuting = true

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }
            defer { self.finish() }

            if let error = error {
                self.completion(.failure(error))
                return
            }

            var result: (text: String?, attachment: AnyAttachmentPayload?) = (nil, nil)

            if let text = item as? String {
                result.text = text
            } else if typeIdentifier == UTType.url.identifier, let url = item as? URL {
                result.text = url.absoluteString
            } else if typeIdentifier == UTType.image.identifier,
                      let image = item as? PlatformImage,
                          let tempURL = try? image.temporaryLocalFileUrl(),
                          let attachment = try? getAttachment(from: tempURL, type: .image, info: [.originalImage: image]) {
                    result.attachment = attachment
            } else if let url = item as? URL,
                      let attachment = try? getAttachment(from: url,
                                                          type: AttachmentType(fileExtension: url.pathExtension),
                                                          info: [:]) {
                result.attachment = attachment
            } else {
                let noURL = NSError(domain: "AttachmentLoadOperation", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file URL returned"])
                self.completion(.failure(noURL))
                return
            }
            self.completion(.success(result))
        }
    }

    /// Creates an attachment from the given URL
    /// - Parameters:
    ///   - url: The URL of the attachment
    ///   - type: The type of the attachment
    ///   - info: The metadata of the attachment
    open func getAttachment(
        from url: URL,
        type: AttachmentType,
        info: [LocalAttachmentInfoKey: Any]
    ) throws -> AnyAttachmentPayload {
        let fileSize = try AttachmentFile(url: url).size

//        let maxAttachmentSize = maxAttachmentSize(for: type)
//        guard fileSize <= maxAttachmentSize else {
//            throw AttachmentValidationError.maxFileSizeExceeded
//        }

        var localMetadata = AnyAttachmentLocalMetadata()
        localMetadata.fileSize = Int(fileSize)

        let attachment = try AnyAttachmentPayload(
            localFileURL: url,
            attachmentType: type,
            localMetadata: localMetadata
        )
        return attachment
    }

    private func finish() {
        isExecuting = false
        isFinished = true
    }

    func imageSize(from url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            return CGSize(width: width, height: height)
        }

        return nil
    }
}

