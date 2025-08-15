//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view controller responsible to search messages.
/// It implements the required functions of the `ChannelListSearchViewController` abstract class.
@available(iOSApplicationExtension, unavailable)
open class MessageSearchViewController: ChannelListSearchViewController, MessageSearchControllerDelegate {
    /// The data of the message list.
    public private(set) var messages: [ChatMessage] = []

    /// The `MessageSearchController` instance to perform the messages search.
    public var messageSearchController: MessageSearchController!

    /// The closure that is triggered whenever a message is selected from the search result.
    public var didSelectMessage: ((Channel, ChatMessage) -> Void)?

    private var isPaginatingMessages: Bool = false

    // MARK: - Lifecycle

    override open func setUp() {
        super.setUp()

        messageSearchController.delegate = self
    }

    // MARK: - ChannelListSearchViewController Abstract Implementations

    override open var hasEmptyResults: Bool {
        messages.isEmpty
    }

    override open func loadSearchResults(with text: String) {
        messageSearchController.search(text: text)
    }

    override open func loadMoreSearchResults() {
        loadMoreMessages()
    }

    // MARK: - Actions

    /// Updates the list view with new data.
    public func reloadMessages() {
        let previousMessages = messages
        let newMessages = Array(messageSearchController.messages)
        let stagedChangeset = StagedChangeset(source: previousMessages, target: newMessages)
        collectionView.reload(using: stagedChangeset, reconfigure: { _ in true }) { [weak self] newMessages in
            self?.messages = newMessages
        }
    }

    open func loadMoreMessages() {
        guard !isPaginatingMessages else {
            return
        }
        isPaginatingMessages = true

        messageSearchController.loadNextMessages { [weak self] _ in
            self?.isPaginatingMessages = false
        }
    }

    // MARK: - Collection View Implementations

    override open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        messages.count
    }

    open override func cellItem(for collectionView: UICollectionView, indexPath: IndexPath, channel: Channel) -> UICollectionViewCell? {
        let cell = collectionView.dequeueReusableCell(with: ChannelListCollectionViewCell.self, for: indexPath)
        guard let message = messages[safe: indexPath.item],
              let cid = message.cid else {
            return cell
        }

        cell.itemView.content = .init(
            channel: channel,
            currentUserId: messageSearchController.client.currentUserId,
            searchResult: .init(text: currentSearchText, message: message)
        )

        return cell

    }

    override open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }

        guard let message = messages[safe: indexPath.item],
              let cid = message.cid,
              let channel = messageSearchController.dataStore.channel(cid: cid) else {
            return
        }

        didSelectMessage?(channel, message)
    }

    // MARK: - MessageSearchControllerDelegate

    open func controller(_ controller: MessageSearchController, didChangeMessages changes: [ListChange<ChatMessage>]) {
        reloadMessages()
    }
}
