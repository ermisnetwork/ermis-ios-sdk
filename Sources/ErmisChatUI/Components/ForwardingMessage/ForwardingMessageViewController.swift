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
            let rLastMessageAt = $1.lastMessageAt ?? $1.updatedAt ?? $1.createdAt
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
        reloadChannels()
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        switch state {
        case .localDataFetched:
            reloadChannels()
        case .remoteDataFetched:
            reloadChannels()
        default:
            break
        }
    }
    // MARK: - TableView
    open func numberOfSections(in tableView: UITableView) -> Int {
        return displayChannels.count
    }

    open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let channel = displayChannels[section]
        if channel.topicsEnabled {
            return channel.topics?.count ?? 1
        }

        return 1
    }

    open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(with: components.forwardingMessageCell.self, for: indexPath)
        cell.itemView.delegate = self
        if let channel = channel(at: indexPath) {
            cell.itemView.content = .init(channel: channel, forwardingState: forwardingState(of: channel))
        }
        cell.itemView.indexPath = indexPath
        return cell
    }

    // MARK: - Helper
    func forwardingState(of channel: Channel) -> ForwardingState {
        forwardStateUpdatingQueue.sync {
            forwardStates[channel.cid] ?? .idle
        }
    }

    func setForwardingState(_ state: ForwardingState, for channel: Channel) {
        forwardStateUpdatingQueue.sync {
            forwardStates[channel.cid] = state
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let currentChannel = self.channel(with: channel.cid),
                  let indexPath = ForwardingChannelListLayout.indexPath(
                    for: channel.cid,
                    in: self.displayChannels
                  ),
                  let cell = self.tableView.cellForRow(at: indexPath) as? ForwardingMessageCell else {
                return
            }
            cell.itemView.indexPath = indexPath
            cell.itemView.content = .init(
                channel: currentChannel,
                forwardingState: self.forwardingState(of: currentChannel)
            )
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

    private func channel(at indexPath: IndexPath) -> Channel? {
        ForwardingChannelListLayout.channel(at: indexPath, in: displayChannels)
    }

    private func channel(with cid: ChannelId) -> Channel? {
        ForwardingChannelListLayout.channel(with: cid, in: displayChannels)
    }
}

enum ForwardingChannelListLayout {
    static func channel(at indexPath: IndexPath, in channels: [Channel]) -> Channel? {
        guard let channel = channels[safe: indexPath.section] else { return nil }
        if channel.topicsEnabled {
            return channel.topics?[safe: indexPath.row]
        }
        return indexPath.row == 0 ? channel : nil
    }

    static func channel(with cid: ChannelId, in channels: [Channel]) -> Channel? {
        guard let indexPath = indexPath(for: cid, in: channels) else { return nil }
        return channel(at: indexPath, in: channels)
    }

    static func indexPath(for cid: ChannelId, in channels: [Channel]) -> IndexPath? {
        for (section, channel) in channels.enumerated() {
            if channel.topicsEnabled {
                if let row = channel.topics?.firstIndex(where: { $0.cid == cid }) {
                    return IndexPath(row: row, section: section)
                }
            } else if channel.cid == cid {
                return IndexPath(row: 0, section: section)
            }
        }
        return nil
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
        guard let message,
              let cid,
              let channel = channel(with: cid) else {
            return
        }
        let transferableAttachments = message.allAttachments.filter { $0.type != .linkPreview }
        let sourceIsEncrypted = message.encryptedData != nil
            || message.decryptedMessage != nil
            || transferableAttachments.contains(where: \.isE2eeOpaqueAsset)
        if sourceIsEncrypted && !channel.isE2eeEnabled {
            let alert = UIAlertController(
                title: L10n.Encryption.ForwardDowngradeAlert.title,
                message: L10n.Encryption.ForwardDowngradeAlert.message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.Alert.Actions.cancel, style: .cancel))
            alert.addAction(UIAlertAction(
                title: L10n.Message.Actions.forward,
                style: .destructive
            ) { [weak self] _ in
                self?.performForward(message: message, channel: channel, sourceIsEncrypted: true)
            })
            present(alert, animated: true)
            return
        }
        performForward(
            message: message,
            channel: channel,
            sourceIsEncrypted: sourceIsEncrypted
        )
    }

    private func performForward(
        message: ChatMessage,
        channel: Channel,
        sourceIsEncrypted: Bool
    ) {
        setForwardingState(.forwarding, for: channel)
        let transferableAttachments = message.allAttachments.filter { $0.type != .linkPreview }
        log.info(
            "[ATTACHMENT_FORWARD] stage=route state=resolved " +
            "attachment_count=\(transferableAttachments.count) " +
            "source_e2ee=\(sourceIsEncrypted) destination_e2ee=\(channel.isE2eeEnabled)"
        )
        let requiresFreshUpload = !transferableAttachments.isEmpty &&
            (sourceIsEncrypted || channel.isE2eeEnabled)
        guard requiresFreshUpload else {
            finishForward(message: message, channel: channel, attachmentOverrides: nil)
            return
        }

        guard let client = messageController?.client else {
            log.error(
                "[ATTACHMENT_FORWARD] stage=source_materialization state=failed " +
                "reason=client_unavailable"
            )
            setForwardingState(.error, for: channel)
            alertsRouter.showMessageForwardingAlert(false)
            return
        }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            var leases: [E2eeAttachmentOriginalLease] = []
            do {
                var payloads: [AnyAttachmentPayload] = []
                payloads.reserveCapacity(transferableAttachments.count)
                leases.reserveCapacity(transferableAttachments.count)
                for attachment in transferableAttachments {
                    try _Concurrency.Task.checkCancellation()
                    let lease = try await client.acquireAttachmentForForwarding(attachment)
                    leases.append(lease)
                    var metadata = attachment.forwardingLocalMetadata
                    // The materialized bytes are authoritative. Legacy forwarded videos can have
                    // absent/stale `file_size`; the upload initializer must measure the local file.
                    metadata.fileSize = nil
                    payloads.append(try AnyAttachmentPayload(
                        localFileURL: lease.localURL,
                        attachmentType: attachment.type,
                        localMetadata: metadata
                    ))
                }
                await MainActor.run {
                    self.finishForward(
                        message: message,
                        channel: channel,
                        attachmentOverrides: payloads,
                        materializationLeases: leases
                    )
                }
            } catch {
                leases.forEach { $0.release() }
                await MainActor.run {
                    log.error(
                        "[ATTACHMENT_FORWARD] stage=source_materialization state=failed " +
                        "error_type=\(String(reflecting: type(of: error)))"
                    )
                    self.setForwardingState(.error, for: channel)
                    self.alertsRouter.showMessageForwardingAlert(false)
                }
            }
        }
    }

    private func finishForward(
        message: ChatMessage,
        channel: Channel,
        attachmentOverrides: [AnyAttachmentPayload]?,
        materializationLeases: [E2eeAttachmentOriginalLease] = []
    ) {
        guard let messageController else {
            materializationLeases.forEach { $0.release() }
            log.error(
                "[ATTACHMENT_FORWARD] stage=enqueue state=failed " +
                "reason=controller_unavailable"
            )
            setForwardingState(.error, for: channel)
            alertsRouter.showMessageForwardingAlert(false)
            return
        }
        messageController.forward(
            message: message,
            to: channel.cid,
            attachmentPayloadOverrides: attachmentOverrides
        ) { [weak self] error in
            materializationLeases.forEach { $0.release() }
            if let error = error {
                log.error(
                    "[ATTACHMENT_FORWARD] stage=enqueue state=failed " +
                    "error_type=\(String(reflecting: type(of: error)))"
                )
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

private extension AnyMessageAttachment {
    var forwardingLocalMetadata: AnyAttachmentLocalMetadata {
        var metadata = AnyAttachmentLocalMetadata()
        metadata.title = title
        metadata.mimeType = mimetype
        metadata.thumbnailData = thumbnailData

        switch type {
        case .image:
            if let image = attachment(payloadType: ImageAttachmentPayload.self) {
                metadata.fileSize = Int(image.file.size)
                metadata.thumbnailData = thumbnailData ?? image.thumbnailData
                if let width = image.originalWidth, let height = image.originalHeight {
                    metadata.originalResolution = (width, height)
                }
            }
        case .video:
            if let video = attachment(payloadType: VideoAttachmentPayload.self) {
                metadata.fileSize = Int(video.file.size)
                metadata.thumbnailData = thumbnailData ?? video.thumbnailData
                metadata.duration = video.duration
            }
        case .audio:
            if let audio = attachment(payloadType: AudioAttachmentPayload.self) {
                metadata.fileSize = Int(audio.file.size)
            }
        case .file:
            if let file = attachment(payloadType: FileAttachmentPayload.self) {
                metadata.fileSize = Int(file.file.size)
            }
        case .voiceRecording:
            if let voice = attachment(payloadType: VoiceRecordingAttachmentPayload.self) {
                metadata.fileSize = Int(voice.file.size)
                metadata.duration = voice.duration
                metadata.waveformData = voice.waveformData
            }
        default:
            break
        }
        return metadata
    }
}
