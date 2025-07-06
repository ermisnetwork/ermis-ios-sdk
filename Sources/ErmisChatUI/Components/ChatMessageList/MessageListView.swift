//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Custom view type used to show the message list.
open class MessageListView: UITableView, BaseViewProtocol, ComponentsProvider {
    private var identifiers: Set<String> = .init()
    private var isInitialized: Bool = false

    // MARK: - Difference Kit and Skipping messages Handling

    // The properties below is to handle the DifferenceKit API. Currently it is
    // internal because these should actually be handled in the `MessageListViewController` but
    // that would make this class obsolete especially the `updateMessages(changes:)` and
    // it would require a lot of breaking changes. So for now, the Diff logic will live here.

    /// The previous messages snapshot before the next update.
    internal var previousMessagesSnapshot: [ChatMessage] = []
    /// The current messages from the data source, including skipped messages.
    /// This property is especially useful when resetting the skipped messages
    /// since we want to reload the data and insert back the skipped messages, for this,
    /// we update the messages data with the one originally reported by the data controller.
    internal var currentMessagesFromDataSource: LazyCachedMapCollection<ChatMessage> = []

    /// The new messages snapshot reported by the channel or message controller.
    /// If messages are being skipped, this snapshot doesn't include skipped messages.
    internal var newMessagesSnapshot: LazyCachedMapCollection<ChatMessage> = []

    /// When inserting messages at the bottom, if the user is scrolled up,
    /// we skip adding the message to the UI until the user scrolls back
    /// to the bottom. This is to avoid message list jumps.
    internal var skippedMessages: Set<MessageId> = []

    /// This closure is to update the dataSource when DifferenceKit
    /// reports the data source should be updated.
    internal var onNewDataSource: (([ChatMessage]) -> Void)?

    /// Property used for `adjustContentInsetToPositionMessagesAtTheTop()` to avoid
    /// reseting the content inset more than one time.
    private var requiresContentInsetReset = false

    /// property used for custom spacing in top of the list.
    open var defaultContentInsetTop: CGFloat = 0 {
        didSet {
            adjustContentInsetToPositionMessagesAtTheTop()
        }
    }

    // MARK: Lifecycle

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()

        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setUp()
        setUpUI()
        setUpTheme()
    }

    open func setUp() {
        keyboardDismissMode = .onDrag
        rowHeight = UITableView.automaticDimension
        separatorStyle = .none
        transform = .mirrorY
    }

    open func setUpTheme() { /* default empty implementation */ }
    open func setUpUI() { /* default empty implementation */ }
    open func contentDidChanged() { /* default empty implementation */ }

    override open func layoutSubviews() {
        super.layoutSubviews()

        adjustContentInsetToPositionMessagesAtTheTop()
    }

    // MARK: Public API

    /// Calculates the cell reuse identifier for the given options.
    /// - Parameters:
    ///   - contentViewClass: The type of message content view.
    ///   - customCellViewInjectorType: The type of attachment injector.
    ///   - layoutOptions: The message content view layout options.
    ///   - message: The message data.
    /// - Returns: The cell reuse identifier.
    open func reuseIdentifier(
        contentViewClass: MessageContentView.Type,
        customCellViewInjectorType: CustomCellViewInjector.Type?,
        layoutOptions: MessageLayoutOptions,
        message: ChatMessage?
    ) -> String {
        var components = [
            MessageCell.reuseId,
            String(layoutOptions.id),
            String(describing: contentViewClass)
        ]
        
        /// If the message should render mixed attachments, the id should be based on the underlying injectors.
        if let mixedAttachmentInjector = customCellViewInjectorType as? MixedAttachmentViewInjector.Type {
            let injectors = mixedAttachmentInjector.injectors(for: message)
            components.append(contentsOf: injectors.map(String.init(describing:)))
        } else if let customCellViewInjectorType {
            components.append(String(describing: customCellViewInjectorType))
        }
        
        return components.joined(separator: "_")
    }

    /// Returns the reuse identifier of the given cell.
    /// - Parameter cell: The cell to calculate reuse identifier for.
    /// - Returns: The reuse identifier.
    open func reuseIdentifier(for cell: MessageCell?) -> String? {
        guard
            let cell = cell,
            let messageContentView = cell.messageContentView,
            let layoutOptions = messageContentView.layoutOptions
        else { return nil }

        return reuseIdentifier(
            contentViewClass: type(of: messageContentView),
            customCellViewInjectorType: messageContentView.customCellViewInjector.map { type(of: $0) },
            layoutOptions: layoutOptions,
            message: messageContentView.content
        )
    }

    /// Dequeues the message cell. Registers the cell for received combination of `contentViewClass + layoutOptions`
    /// if needed.
    /// - Parameters:
    ///   - contentViewClass: The type of content view the cell will be displaying.
    ///   - layoutOptions: The option set describing content view layout.
    ///   - indexPath: The cell index path.
    ///   - message: The message data.
    /// - Returns: The instance of `MessageCollectionViewCell` set up with the
    /// provided `contentViewClass` and `layoutOptions`
    open func dequeueReusableCell(
        contentViewClass: MessageContentView.Type,
        customCellViewInjectorType: CustomCellViewInjector.Type?,
        layoutOptions: MessageLayoutOptions,
        for indexPath: IndexPath,
        message: ChatMessage?
    ) -> MessageCell {
        let reuseIdentifier = self.reuseIdentifier(
            contentViewClass: contentViewClass,
            customCellViewInjectorType: customCellViewInjectorType,
            layoutOptions: layoutOptions,
            message: message
        )

        // There is no public API to find out
        // if the given `identifier` is registered.
        if !identifiers.contains(reuseIdentifier) {
            identifiers.insert(reuseIdentifier)
            register(MessageCell.self, forCellReuseIdentifier: reuseIdentifier)
        }

        let cell = dequeueReusableCell(with: MessageCell.self, for: indexPath, reuseIdentifier: reuseIdentifier)

        cell.setMessageContentIfNeeded(
            contentViewClass: contentViewClass,
            customCellViewInjectorType: customCellViewInjectorType,
            options: layoutOptions
        )

        cell.messageContentView?.indexPath = { [weak cell, weak self] in
            guard let cell = cell else { return nil }
            return self?.indexPath(for: cell)
        }

        cell.contentView.transform = .mirrorY

        return cell
    }

    /// Scroll to the bottom of the message list.
    open func scrollToBottom(animated: Bool = true) {
        let rowsRange = 0..<numberOfRows(inSection: 0)
        let lastMessageIndexPath = IndexPath(row: 0, section: 0)
        let prevMessageIndexPath = IndexPath(row: 1, section: 0)

        if rectForRow(at: prevMessageIndexPath).minY < contentOffset.y,
           rowsRange.contains(prevMessageIndexPath.row) {
            scrollToRow(at: prevMessageIndexPath, at: .top, animated: animated)
        }

        if rowsRange.contains(lastMessageIndexPath.row) {
            scrollToRow(at: lastMessageIndexPath, at: .top, animated: animated)
        }
    }

    /// Scroll to the top of the message list.
    open func scrollToTop(animated: Bool = true) {
        let numberOfRows = numberOfRows(inSection: 0)
        guard numberOfRows > 0 else { return }
        let indexPath = IndexPath(row: numberOfRows - 1, section: 0)
        scrollToRow(at: indexPath, at: .bottom, animated: animated)
    }

    /// A Boolean that returns true if the bottom cell is fully visible.
    /// Which is also means that the collection view is fully scrolled to the boom.
    open var isLastCellFullyVisible: Bool {
        guard numberOfRows(inSection: 0) > 0 else { return false }

        let cellRect = rectForRow(at: .init(row: 0, section: 0))

        return cellRect.minY >= contentOffset.y
    }

    /// Updates the table view data with given `changes`.
    open func updateMessages(
        with changes: [ListChange<ChatMessage>],
        completion: (() -> Void)? = nil
    ) {
        let previousMessagesSnapshot = self.previousMessagesSnapshot
        let newMessagesWithoutSkipped = newMessagesSnapshot.filter {
            !self.skippedMessages.contains($0.id)
        }
        adjustContentInsetToPositionMessagesAtTheTop()
        UIView.performWithoutAnimation {
            reloadMessages(
                previousSnapshot: previousMessagesSnapshot,
                newSnapshot: newMessagesWithoutSkipped,
                with: .fade,
                completion: { [weak self] in
                    completion?()
                    self?.adjustContentInsetToPositionMessagesAtTheTop()
                }
            )
        }
    }

    /// Reset the skipped messages and reload the message list
    /// with the messages originally reported from the data source.
    internal func reloadSkippedMessages() {
        skippedMessages = []
        newMessagesSnapshot = currentMessagesFromDataSource
        onNewDataSource?(Array(newMessagesSnapshot))
        reloadData()
        scrollToBottom()
    }

    /// Adjusts the content inset so that messages are inserted at the top when there are few messages.
    /// This is will be executed if the `Components.shouldMessagesStartAtTheTop` is enabled.
    internal func adjustContentInsetToPositionMessagesAtTheTop() {
        guard components.shouldMessagesStartAtTheTop else {
            contentInset.bottom = defaultContentInsetTop
            return
        }

        // If the height of message list is more than the content height
        // then adjust the content inset so that it fills the remaining height
        // otherwise do not set any content inset.
        let contentSizeHeight = contentSize.height
        let messageListHeight = frame.height
        let newContentInset = messageListHeight - contentSizeHeight - defaultContentInsetTop
        if newContentInset > 0 {
            contentInset.top = newContentInset
            showsVerticalScrollIndicator = false
            requiresContentInsetReset = true
            // In case  we already removed the content inset, there's
            // no need to do it every time.
        } else if requiresContentInsetReset {
            requiresContentInsetReset = false
            contentInset.top = defaultContentInsetTop
            showsVerticalScrollIndicator = true
        } else {
            contentInset.bottom = defaultContentInsetTop
        }
    }
}

// MARK: Helpers

private extension CGAffineTransform {
    static let mirrorY = Self(scaleX: 1, y: -1)
}
