//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit
import Combine

/// Controller responsible for displaying the channel messages.
@available(iOSApplicationExtension, unavailable)
open class ChannelViewController: _ViewController,
                                  UIProvider,
                                  MessageListViewControllerDataSource,
                                  MessageListViewControllerDelegate,
                                  ChannelControllerDelegate,
                                  EventsControllerDelegate,
                                  AudioQueuePlayerDatasource
{
    /// Controller for observing data changes within the channel.
    open var channelController: ChannelController!

    /// User search controller for suggestion users when typing in the composer.
    open lazy var userSuggestionSearchController: UserSearchController =
        channelController.client.userSearchController()

    /// A controller for observing web socket events.
    public lazy var eventsController: EventsController = client.eventsController()

    /// A message controller for unpin message
    var messageController: MessageController?

    open var invitingHeight: CGFloat {
        return invitingView.ideaHeight
    }

    public var client: ErmisClient {
        channelController.client
    }

    /// Component responsible for setting the correct offset when keyboard frame is changed.
    open lazy var keyboardHandler: KeyboardHandler = ComposerKeyboardHandler(
        composerParentVC: self,
        composerBottomConstraint: messageComposerBottomConstraint,
        messageListVC: messageListVC
    )

    /// The message list component responsible to render the messages.
    open lazy var messageListVC: MessageListViewController = components
        .messageListVC
        .init()

    /// Controller that handles the composer view
    open private(set) lazy var messageComposerVC = components
        .messageComposerVC
        .init()

    /// The audioPlayer  that will be used for the playback of VoiceRecordings
    open private(set) lazy var audioPlayer: AudioPlaying = components
        .audioPlayer
        .init()

    /// The provider that will be asked to provide the next VoiceRecording to play automatically once the
    /// currently playing one, finishes.
    open private(set) lazy var audioQueuePlayerNextItemProvider: AudioQueuePlayerNextItemProvider = components
        .audioQueuePlayerNextItemProvider
        .init()

    /// Header View
    open private(set) lazy var headerView: ChannelHeaderView = components
        .channelHeaderView.init()
        .withoutAutoresizingMaskConstraints

    /// The pin message view.
    open lazy var pinnedMessageView: PinnedMessageView = components
        .pinnedMessageView
        .init()
        .withoutAutoresizingMaskConstraints

    /// View show when user in direct channel, and directUser not accept invitation yet.
    open private(set) lazy var invitingView = components
        .channelInvitingView.init()
        .withoutAutoresizingMaskConstraints

    /// View show when user role pending
    open private(set) lazy var acceptInvitationView = components
        .channelAcceptInvitationView
        .init()
        .withoutAutoresizingMaskConstraints

    /// The `OngoingCallView` instance show when have ongoing call.
    open private(set) lazy var ongoingCallView = components
        .ongoingCallVIew
        .init()
        .withoutAutoresizingMaskConstraints

    open lazy var alertRouter = components.alertsRouter.init(rootViewController: self)

    open var shouldShowOngoingCallView: Bool {
        return false
    }
    /// The message list top constaint.
    public
    var messageListTopConstraint: NSLayoutConstraint?

    /// The inviting view height constraint.
    public
    var invitingViewHeightConstraint: NSLayoutConstraint?

    /// The message composer bottom constraint used for keyboard animation handling.
    public 
    var messageComposerBottomConstraint: NSLayoutConstraint?

    /// A boolean value indicating whether the last message is fully visible or not.
    open 
    var isLastMessageFullyVisible: Bool {
        messageListVC.listView.isLastCellFullyVisible
    }

    internal var isViewVisible: ((ChannelViewController) -> Bool) = { channelVC in
        guard UIApplication.shared.applicationState == .active else { return false }
        return channelVC.viewIfLoaded?.window != nil
    }

    /// A boolean value indicating whether it should mark the channel read.
    public var shouldMarkChannelRead: Bool {
        guard isViewVisible(self), case .remoteDataFetched = channelController.state else {
            return false
        }

        guard components.isJumpToUnreadEnabled else {
            return isLastMessageFullyVisible && isFirstPageLoaded
        }

        return isLastMessageVisibleOrSeen && !hasMarkedMessageAsUnread && hasSeenFirstUnreadMessage && isFirstPageLoaded
    }

    private var isLastMessageVisibleOrSeen: Bool {
        hasSeenLastMessage || isLastMessageFullyVisible
    }

    /// A component responsible to handle when to load new or old messages.
    private lazy var viewPaginationHandler: StatefulViewPaginationHandling = {
        InvertedScrollViewPaginationHandler.make(scrollView: messageListVC.listView)
    }()

    var throttler: Throttler = Throttler(interval: 3, queue: .main)

    /// Determines if a messaged had been marked as unread in the current session
    private var hasMarkedMessageAsUnread: Bool {
        channelController.isMarkedAsUnread
    }

    /// Determines whether first unread message has been seen
    private var hasSeenFirstUnreadMessage: Bool = false

    /// Determines whether last cell has been seen since the last time it was marked as read
    private var hasSeenLastMessage: Bool = false

    /// The id of the first unread message
    private var firstUnreadMessageId: MessageId?

    /// In case the given around message id is from a thread, we need to jump to the parent message and then the reply.
    internal var initialReplyId: MessageId?


    private var isGuest: Bool {
        return channelController.channel?.isGuess ?? false
    }
    /// Inccase controller finished sync with error before view load, this flag will mark
    /// that we need closed channelVC when it finished load.
    private var shouldClosedWhenLoad: Bool = false

    private lazy var attachmentSaver = channelController.client.attachmentSaver(presentingFrom: self)

    private lazy var cancelBags: Set<AnyCancellable> = []

    // MARK: - Setup
    override open func setUp() {
        super.setUp()

        eventsController.delegate = self

        messageListVC.delegate = self
        messageListVC.dataSource = self
        messageListVC.client = client

        messageComposerVC.userSearchController = userSuggestionSearchController

        setChannelControllerToComposerIfNeeded(cid: channelController.cid)

        // If the given message id is a reply that is inside a thread, we need
        // to fetch the parent message, jump to the parent message and then open
        // the thread so that we can jump to the thread reply.
        // For this, we need to manipulate the original channel controller to contain
        // the parent message id instead of the reply id.
        if let initialMessageId = channelController.channelQuery.pagination?.parameter?.aroundMessageId,
           let message = channelController.dataStore.message(id: initialMessageId),
           let parentMessageId = getParentMessageId(forMessageInsideThread: message) {
            initialReplyId = initialMessageId
            channelController = makeChannelController(forParentMessageId: parentMessageId)
        }

        channelController.delegate = self
        channelController.synchronize { [weak self] error in
            self?.didFinishSynchronizing(with: error)
        }

        if channelController.channelQuery.pagination?.parameter == nil {
            // Load initial messages from cache if loading the first page
            messages = Array(channelController.messages)
        }

        // Handle pagination
        viewPaginationHandler.onNewTopPage = { [weak self] notifyElementsCount, completion in
            notifyElementsCount(self?.channelController.messages.count ?? 0)
            self?.channelController.loadPreviousMessages(completion: completion)
        }
        viewPaginationHandler.onNewBottomPage = { [weak self] notifyElementsCount, completion in
            notifyElementsCount(self?.channelController.messages.count ?? 0)
            self?.channelController.loadNextMessages(completion: completion)
        }

        messageListVC.audioPlayer = audioPlayer
        messageComposerVC.audioPlayer = audioPlayer

        if let queueAudioPlayer = audioPlayer as? ErmisAudioQueuePlayer {
            queueAudioPlayer.dataSource = self
        }

        messageListVC.swipeToReplyGestureHandler.onReply = { [weak self] message in
            self?.messageComposerVC.content.quoteMessage(message)
        }

        if let composerUnsentContent = channelController.channel?.composerUnsentContent {
            self.messageComposerVC.resumeUnsentContent(composerUnsentContent)
        }

        acceptInvitationView.delegate = self
        pinnedMessageView.delegate = self

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notificaiton in
                self?.channelController.synchronize { [weak self] error in
                }
            }
            .store(in: &cancelBags)

        NotificationCenter.default.publisher(for: .callVCDidHidden)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.ongoingCallView.userInfo = notification.userInfo
                self?.setOngoingCallViewHidden(false)
            }
            .store(in: &cancelBags)

        NotificationCenter.default.publisher(for: .ongoingCallViewDidTap)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.setOngoingCallViewHidden(true)
            }
            .store(in: &cancelBags)

        NotificationCenter.default.publisher(for: .callDidEnded)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let callId = notification.userInfo?["call_id"] as? String,
                      callId == self?.ongoingCallView.callId else {
                    return
                }
                self?.setOngoingCallViewHidden(true)
            }
            .store(in: &cancelBags)
    }
    
    override open func setUpUI() {
        super.setUpUI()

        view.backgroundColor = theme.colors.surface

        addChildViewController(messageListVC, targetView: view)

        messageListTopConstraint = messageListVC.view.topAnchor.pin(equalTo: view.safeAreaLayoutGuide.topAnchor)
        messageListVC.view.pin(anchors: [.leading, .trailing], to: view.safeAreaLayoutGuide)

        view.addSubview(invitingView)
        invitingViewHeightConstraint = invitingView.heightAnchor.constraint(equalToConstant: invitingHeight)
        invitingView.pin(anchors: [.leading, .trailing], to: view)

        addChildViewController(messageComposerVC, targetView: view)
        messageComposerVC.view.pin(anchors: [.leading, .trailing], to: view)
        messageComposerVC.view.topAnchor.pin(equalTo: invitingView.bottomAnchor).isActive = true
        messageComposerBottomConstraint = messageComposerVC.view.bottomAnchor.pin(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            messageListTopConstraint!,
            invitingViewHeightConstraint!,
            invitingView.makeConstraint(attribute: .top, toItem: messageListVC.view, attribute: .bottom),
            messageComposerBottomConstraint!

        ])

        if let cid = channelController.cid {
            headerView.channelController = client.channelController(for: cid)
        }

        view.addSubview(pinnedMessageView)
        pinnedMessageView.topAnchor.pin(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16).isActive = true
        pinnedMessageView.pin(anchors: [.leading], to: view, contant: 16)
        pinnedMessageView.pin(anchors: [.centerX], to: view)
        pinnedMessageView.heightAnchor.pin(greaterThanOrEqualToConstant: 72).isActive = true

        // Accept Invitation View
        view.addSubview(acceptInvitationView)
        acceptInvitationView.pin(anchors: [.top, .bottom, .leading, .trailing], to: view)
        updateInvitationView()
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: headerView)
        navigationItem.largeTitleDisplayMode = .never
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if shouldClosedWhenLoad {
            closed()
        }
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
//        channelController.delegate = self
        keyboardHandler.start()

        if shouldMarkChannelRead {
            markRead()
        }
    }

    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        markRead()
        keyboardHandler.stop()

        resignFirstResponder()
    }

    /// Called when the syncing of the `channelController` is finished.
    /// - Parameter error: An `error` if the syncing failed; `nil` if it was successful.
    open func didFinishSynchronizing(with error: Error?) {
        if let error = error {
            log.error("Error when synchronizing ChannelController: \(error)")
            if let error = error as? ClientError, let ermisApiError = error.ermisApiError {
                if ermisApiError.type == .notAMemberOfChannel {
                        closed()
                        shouldClosedWhenLoad = true
//                    }
                }
            }
        }
        updateScrollToBottomButtonCount()
        setChannelControllerToComposerIfNeeded(cid: channelController.cid)
        messageComposerVC.contentDidChanged()

        updateAllUnreadMessagesRelatedComponents()

        if let messageId = channelController.channelQuery.pagination?.parameter?.aroundMessageId {
            // Jump to a message when opening the channel.
            jumpToMessage(id: messageId, animated: components.shouldAnimateJumpToMessageWhenOpeningChannel)

            if let replyId = initialReplyId {
                // Jump to a parent message when opening the channel, and then to the reply.
                // The delay is necessary so that the animation does not happen to quickly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.jumpToMessage(
                        id: replyId,
                        animated: self.components.shouldAnimateJumpToMessageWhenOpeningChannel
                    )
                }
            }
        } else if let messageId = channelController.jumpingMessageId {
            jumpToMessage(id: messageId, animated: components.shouldAnimateJumpToMessageWhenOpeningChannel)
            channelController.jumpingMessageId = nil
        } else if components.shouldJumpToUnreadWhenOpeningChannel {
            // Jump to the unread message.
            messageListVC.jumpToUnreadMessage(animated: components.shouldAnimateJumpToMessageWhenOpeningChannel)
        }
    }

    private func setChannelControllerToComposerIfNeeded(cid: ChannelId?) {
        guard messageComposerVC.channelController == nil, let cid = cid else { return }
        messageComposerVC.channelController = client.channelController(for: cid)
    }

    // MARK: - Actions

    /// Marks the channel read and updates the UI optimistically.
    public func markRead() {
        channelController.markRead()
        hasSeenLastMessage = false
        updateJumpToUnreadRelatedComponents()
        updateScrollToBottomButtonCount()
    }

    /// Jump to a given message.
    /// In case the message is already loaded, it directly goes to it.
    /// If not, it will load the messages around it and go to that page.
    ///
    /// This function is an high-level abstraction of `messageListVC.jumpToMessage(id:onHighlight:)`.
    ///
    /// - Parameters:
    ///   - id: The id of message which the message list should go to.
    ///   - animated: `true` if you want to animate the change in position; `false` if it should be immediate.
    ///   - shouldHighlight: Whether the message should be highlighted when jumping to it. By default it is highlighted.
    public func jumpToMessage(id: MessageId, animated: Bool = true, shouldHighlight: Bool = true) {
        if shouldHighlight {
            messageListVC.jumpToMessage(id: id, animated: animated) { [weak self] indexPath in
                self?.messageListVC.highlightCell(at: indexPath)
            }
            return
        }

        messageListVC.jumpToMessage(id: id, animated: animated)
    }

    open
    func closed() {
        navigationController?.popViewController(animated: true)
    }

    public func setOngoingCallViewHidden(_ isHidden: Bool) {
        guard shouldShowOngoingCallView,
              let cid = ongoingCallView.userInfo?["cid"] as? ChannelId,
              cid == channelController.channel?.cid else {
            return
        }

        if ongoingCallView.superview == nil {
            self.view.addSubview(ongoingCallView)
            ongoingCallView.pin(anchors: [.top, .leading, .trailing], to: view.safeAreaLayoutGuide)
        }

        ongoingCallView.isHidden = isHidden
        messageListTopConstraint?.constant = isHidden ? 0 : 32
    }

    /// Show forwarding message screen.
    open func showForwardingMessageScreen(for chatMessage: ChatMessage) {
        guard let membership = channelController.channel?.membership, let cid = channelController.cid else { return }
        let forwardingMessageVC = components
            .forwardingMessageViewController
            .init()
        let channelListQuery: ChannelListQuery = .init(
            filter: .joinedChannels(memberId: membership.userId,
                                    projectId: channelController.client.projectId ?? ""),
            sort: [
                .init(key: .lastMessageAt),
                .init(key: .updatedAt)
            ]
        )
        let channelListController = channelController.client.channelListController(query: channelListQuery)
        forwardingMessageVC.message = chatMessage
        forwardingMessageVC.controller = channelListController
        forwardingMessageVC.messageController = channelController.client.messageController(cid: cid, messageId: chatMessage.id)

        let navigationController = UINavigationController(rootViewController: forwardingMessageVC)
        present(navigationController, animated: true)
    }

    /// Show pinned message list screen.
    open func showPinnedMessageList() {
        guard let cid = channelController.cid else {
            return
        }
        let vc = components.pinnedMessageListViewController.init()
        vc.channelController = client.channelController(for: cid)
        vc.delegate = self
        navigationController?.pushViewController(vc, animated: true)
    }

    // Unpin last pinned message
    open func unpinLastPinnedMessage() {
        self.alertRouter.showMessageUnpinConfirmationAlert { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard let channel = channelController.channel,
                  let lastPinnedMessage = channel.pinnedMessages.first  else { return }
            messageController = client.messageController(cid: channel.cid,
                                                                           messageId: lastPinnedMessage.id)

            messageController?.unpin { [weak self] error in
                guard let self else { return }
                if let error {
                    self.alertRouter.showMessageUnpinResultAlert(false)
                    return
                }
                self.alertRouter.showMessageUnpinResultAlert(true)

            }
        }
    }
    // MARK: - Invitation

    /// Accept invitaion to join this channel
    /// - Parameters:
    ///    - completion: Called when the API call is finished. Called with `Error` if failed
    open func acceptInvitation(completion: @escaping (Error?) -> Void) {
        channelController.acceptInvite(completion: completion)
    }

    /// Reject invitation to join this channel
    /// - Parameters:
    ///    - completion: Called when the API call is finished. Called with `Error` if failed
    open func rejectInvitation(completion: @escaping (Error?) -> Void) {
        channelController.rejectInvite(completion: completion)
    }

    /// Skip invitation to join this channel
    open func skipInvitation() {
        self.navigationController?.popViewController(animated: true)
    }

    /// Show dialog when user don't have enough conditions to join channel
    open func showChannelConditionRequiredAlert(conditions: [ChannelConditionPayload]) {
        let alert = ChannelConditionRequiredViewController()
        alert.delegate = self
        alert.content = .init(channel: self.channelController.channel,
                              channelConditions: conditions)
        alert.modalPresentationStyle = .overCurrentContext
        present(alert, animated: false)
    }

    // MARK: - MessageListViewControllerDataSource

    public var messages: [ChatMessage] = []

    public var isFirstPageLoaded: Bool {
        channelController.hasLoadedAllNextMessages
    }

    public var isLastPageLoaded: Bool {
        channelController.hasLoadedAllPreviousMessages
    }

    open func channel(for vc: MessageListViewController) -> Channel? {
        channelController.channel
    }

    open func numberOfMessages(in vc: MessageListViewController) -> Int {
        messages.count
    }

    open func messageListVC(_ vc: MessageListViewController, messageAt indexPath: IndexPath) -> ChatMessage? {
        messages[safe: indexPath.item]
    }

    open func messageListVC(
        _ vc: MessageListViewController,
        messageLayoutOptionsAt indexPath: IndexPath
    ) -> MessageLayoutOptions {
        guard let channel = channelController.channel else { return [] }

        return components.messageLayoutOptionsResolver.optionsForMessage(
            at: indexPath,
            in: channel,
            with: AnyRandomAccessCollection(messages),
            theme: theme
        )
    }

    public func messageListVC(
        _ vc: MessageListViewController,
        shouldLoadPageAroundMessageId messageId: MessageId,
        _ completion: @escaping ((Error?) -> Void)
    ) {
        if let message = channelController.dataStore.message(id: messageId),
           let parentMessageId = getParentMessageId(forMessageInsideThread: message) {
            let replyId = message.id
            messageListVC.showThread(messageId: parentMessageId, at: replyId)
            return
        }

        channelController.loadPageAroundMessageId(messageId) { [weak self] error in
            self?.updateJumpToUnreadRelatedComponents()
            completion(error)
        }
    }

    open func messageListVCShouldLoadFirstPage(
        _ vc: MessageListViewController
    ) {
        channelController.loadFirstPage()
    }

    // MARK: - MessageListViewControllerDelegate

    open func messageListVC(
        _ vc: MessageListViewController,
        willDisplayMessageAt indexPath: IndexPath
    ) {
        guard !hasSeenFirstUnreadMessage else { return }

        let message = messageListVC(vc, messageAt: indexPath)
        if message?.id == firstUnreadMessageId {
            hasSeenFirstUnreadMessage = true
            updateJumpToUnreadRelatedComponents()
        }
    }

    open func messageListVC(
        _ vc: MessageListViewController,
        didTapOnAction actionItem: MessageActionItem,
        for message: ChatMessage
    ) {
        switch actionItem {
        case is EditActionItem:
            dismiss(animated: true) { [weak self] in
                self?.messageComposerVC.content.editMessage(message)
                self?.messageComposerVC.composerView.inputMessageView.textView.becomeFirstResponder()
            }

        case is DownloadActionItem:
            dismiss(animated: true) { [weak self] in
                self?.attachmentSaver.downloadAttachments(attachments: message.allAttachments, completion: { [weak self] error in
                    self?.alertRouter.showDownloadAttachmentAlertResult(isSuccess: error == nil)
                })
            }
        case is ForwardActionItem:
            dismiss(animated: true) { [weak self] in
                self?.showForwardingMessageScreen(for: message)
            }
        case is InlineReplyActionItem:
            dismiss(animated: true) { [weak self] in
                self?.messageComposerVC.content.quoteMessage(message)
            }
        case is ThreadReplyActionItem:
            dismiss(animated: true) { [weak self] in
                self?.messageListVC.showThread(messageId: message.id)
            }
        case is MarkUnreadActionItem:
            alertRouter.showToast(title: "Feature not implemented yet")
//            dismiss(animated: true) { [weak self] in
//                self?.channelController.markUnread(from: message.id) { result in
//                    if case let .success(channel) = result {
//                        self?.updateAllUnreadMessagesRelatedComponents(channel: channel)
//                    }
//                }
//            }
        default:
            return
        }
    }

    public func messageListShouldShowJumpToUnread(_ vc: MessageListViewController) -> Bool {
        true
    }

    public func messageListDidDiscardUnreadMessages(_ vc: MessageListViewController) {
        markRead()
        updateJumpToUnreadRelatedComponents()
    }

    open func messageListVC(
        _ vc: MessageListViewController,
        scrollViewDidScroll scrollView: UIScrollView
    ) {
        if !hasSeenLastMessage && isLastMessageFullyVisible {
            hasSeenLastMessage = true
        }
        if shouldMarkChannelRead {
            throttler.execute { [weak self] in
                self?.markRead()
            }
        }
    }

    open func messageListVC(
        _ vc: MessageListViewController,
        didTapOnMessageListView messageListView: MessageListView,
        with gestureRecognizer: UITapGestureRecognizer
    ) {
        messageComposerVC.dismissSuggestions()
    }

    open func messageListVC(
        _ vc: MessageListViewController,
        headerViewForMessage message: ChatMessage,
        at indexPath: IndexPath
    ) -> MessageCellHeaderFooterView? {
        let shouldShowDate = vc.shouldShowDateSeparator(forMessage: message, at: indexPath)
        let shouldShowUnreadMessages = components.isUnreadMessagesSeparatorEnabled && message.id == firstUnreadMessageId

        guard (shouldShowDate || shouldShowUnreadMessages), let channel = channelController.channel else {
            return nil
        }

        let header = components.messageHeaderDecorationView.init()
        header.content = ChannelMessageHeaderDecoratorViewContent(
            message: message,
            channel: channel,
            dateFormatter: vc.dateSeparatorFormatter,
            shouldShowDate: shouldShowDate,
            shouldShowUnreadMessages: shouldShowUnreadMessages
        )
        return header
    }

    open func messageListVC(
        _ vc: MessageListViewController,
        footerViewForMessage message: ChatMessage,
        at indexPath: IndexPath
    ) -> MessageCellHeaderFooterView? {
        nil
    }

    // MARK: - ChannelControllerDelegate

    open func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    ) {
        messageListVC.setPreviousMessagesSnapshot(messages)
        messageListVC.setNewMessagesSnapshot(channelController.messages)
        messageListVC.updateMessages(with: changes) { [weak self] in
            guard let self = self else { return }

            if let unreadCount = channelController.channel?.unreadCount.messages, channelController.firstUnreadMessageId == nil && unreadCount == 0 {
                self.hasSeenFirstUnreadMessage = true
            }

            self.updateJumpToUnreadRelatedComponents()
            if self.shouldMarkChannelRead {
                self.throttler.execute {
                    self.markRead()
                }
            } else if !self.hasSeenFirstUnreadMessage {
                self.updateUnreadMessagesBannerRelatedComponents()
            }
        }
        viewPaginationHandler.updateElementsCount(with: channelController.messages.count)
    }

    open func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    ) {
        // Not member of this channel, closed channel view controller.
        if !channel.item.isPublic, channel.item.membership == nil {
            closed()
            shouldClosedWhenLoad = true
        }
        updateScrollToBottomButtonCount()
        updateJumpToUnreadRelatedComponents()

        if headerView.channelController == nil, let cid = channelController.cid {
            headerView.channelController = client.channelController(for: cid)
        }
        updateInvitationView()

        if let channel = self.channelController.channel,
           let lastestPinnedMessage = channel.pinnedMessages.first {
            pinnedMessageView.content = .init(message: lastestPinnedMessage,
                                              channel: channel,
                                              pinnedMessageCount: channel.pinnedMessages.count)
            messageListVC.listView.defaultContentInsetTop = pinnedMessageView.bounds.height + 32
        } else {
            pinnedMessageView.content = nil
            messageListVC.listView.defaultContentInsetTop = 0
        }
    }

    open func channelController(
        _ channelController: ChannelController,
        didChangeTypingUsers typingUsers: Set<ChatUser>
    ) {
        guard channelController.channel?.canSendTypingEvents == true else { return }

        let typingUsersWithoutCurrentUser = typingUsers
            .sorted { $0.id < $1.id }
            .filter { $0.id != self.client.currentUserId }

        if typingUsersWithoutCurrentUser.isEmpty {
            messageListVC.hideTypingIndicator()
        } else {
            messageListVC.showTypingIndicator(typingUsers: typingUsersWithoutCurrentUser)
        }
    }

    // MARK: - EventsControllerDelegate

    open func eventsController(_ controller: EventsController, didReceiveEvent event: Event) {
        if let newMessagePendingEvent = event as? NewMessagePendingEvent {
            let newMessage = newMessagePendingEvent.message
            if !isFirstPageLoaded && newMessage.isSentByCurrentUser && !newMessage.isPartOfThread {
                channelController.loadFirstPage()
            }
        }

        if let newMessageErrorEvent = event as? NewMessageErrorEvent {
            let messageId = newMessageErrorEvent.messageId
            let error = newMessageErrorEvent.error
            guard let message = channelController.dataStore.message(id: messageId) else {
                debugPrint("New Message Error: \(error) MessageId: \(messageId)")
                return
            }
            debugPrint("New Message Error: \(error) Message: \(message)")
        }
    }

    // MARK: - AudioQueuePlayerDatasource

    open func audioQueuePlayerNextAssetURL(
        _ audioPlayer: AudioPlaying,
        currentAssetURL: URL?
    ) -> URL? {
        audioQueuePlayerNextItemProvider.findNextItem(
            in: messages,
            currentVoiceRecordingURL: currentAssetURL,
            lookUpScope: .subsequentMessagesFromUser
        )
    }
}

// MARK: - Helpers

private extension ChannelViewController {
    /// Returns a parent message id if the given message is a reply inside a thread only.
    func getParentMessageId(forMessageInsideThread message: ChatMessage) -> MessageId? {
        guard message.isPartOfThread else {
            return nil
        }

        return message.parentMessageId
    }

    func makeChannelController(forParentMessageId parentMessageId: MessageId) -> ChannelController {
        var newQuery = channelController.channelQuery
        let pageSize = newQuery.pagination?.pageSize ?? .messagesPageSize
        newQuery.pagination = MessagesPagination(pageSize: pageSize, parameter: .around(parentMessageId))
        return client.channelController(
            for: newQuery,
            channelListQuery: channelController.channelListQuery,
            messageOrdering: channelController.messageOrdering
        )
    }

    func updateAllUnreadMessagesRelatedComponents(channel: Channel? = nil) {
        updateScrollToBottomButtonCount(channel: channel)
        updateJumpToUnreadRelatedComponents(channel: channel)
        updateUnreadMessagesBannerRelatedComponents(channel: channel)
    }

    func updateScrollToBottomButtonCount(channel: Channel? = nil) {
        let channelUnreadCount = (channel ?? channelController.channel)?.unreadCount ?? .noUnread
        messageListVC.scrollToBottomButton.content = channelUnreadCount
    }

    func updateJumpToUnreadRelatedComponents(channel: Channel? = nil) {
        let firstUnreadMessageId = channel.flatMap { channelController.getFirstUnreadMessageId(for: $0) } ?? channelController.firstUnreadMessageId
        let lastReadMessageId = client.currentUserId.flatMap { channel?.lastReadMessageId(userId: $0) } ?? channelController.lastReadMessageId

        messageListVC.updateJumpToUnreadMessageId(
            firstUnreadMessageId,
            lastReadMessageId: lastReadMessageId
        )
        messageListVC.updateJumpToUnreadButtonVisibility()
    }

    func updateUnreadMessagesBannerRelatedComponents(channel: Channel? = nil) {
        let firstUnreadMessageId = channel.flatMap { channelController.getFirstUnreadMessageId(for: $0) } ?? channelController.firstUnreadMessageId
        self.firstUnreadMessageId = firstUnreadMessageId
        messageListVC.updateUnreadMessagesSeparator(at: firstUnreadMessageId)
    }

    func updateInvitationView() {
        var isAcceptInvitationViewVisible = false
        var isShowInvitationViewVisible = false
        if let channel = channelController.channel {
            isAcceptInvitationViewVisible = channel.membership?.memberRole == .pending || channel.membership?.memberRole == .skipped
            isShowInvitationViewVisible = channel.isDirectMessageChannel && (channel.directUserMembership?.memberRole == .pending || channel.directUserMembership?.memberRole == .skipped)
        }
        acceptInvitationView.isVisible = isAcceptInvitationViewVisible
        if isAcceptInvitationViewVisible {
            acceptInvitationView.content = (channelController.channel, client.currentUserId)
        }
        let constant: CGFloat = isShowInvitationViewVisible ? invitingHeight : 0
        invitingViewHeightConstraint?.constant = constant
        invitingView.directUserName = channelController.channel?.directUserMembership?.name
        invitingViewHeightConstraint?.constant = isShowInvitationViewVisible ? invitingHeight : 0
    }
}
// MARK: - ChannelAcceptInvitationView

extension ChannelViewController: ChannelAcceptInvitationViewDelegate {
    public func channelAcceptInvitationViewDidAccept(_ view: ChannelAcceptInvitationView) {
        view.isLoading = true
        acceptInvitation { [weak self] error in
            guard let self else { return }
            view.isLoading = false
            if let ermisError = (error as? ClientError)?.ermisApiError,
               let channelConditions = ermisError.channelConditions {
                showChannelConditionRequiredAlert(conditions: channelConditions)
                return
            }
        }
    }
    
    public func channelAcceptInvitationViewDidReject(_ view: ChannelAcceptInvitationView) {
        view.isLoading = true
        rejectInvitation { _ in
            view.isLoading = false
        }
    }

    public func channelAcceptInvitationViewDidSkip(_ view: ChannelAcceptInvitationView) {
        if channelController.channel?.membership?.memberRole == .pending {
            view.isLoading = true
            rejectInvitation { _ in
                view.isLoading = false
            }
        } else {
            closed()
        }
    }
}

// MARK: - ChannelConditionRequiredAlertViewDelegate
extension ChannelViewController: ChannelConditionRequiredAlertViewDelegate {
    public func channelConditionRequiredAlertDidClose(_ alert: ChannelConditionRequiredView) {
        dismiss(animated: true)
    }
    
    public func channelConditionRequiredAlertDidReCheck(_ alert: ChannelConditionRequiredView) {
        acceptInvitation { [weak self] error in
            guard let self else {
                return
            }
            alert.isLoading = true
            if let error {
                // Show error
            } else {
                dismiss(animated: true)
            }
            alert.isLoading = false
        }
    }
    
    public func channelConditionRequiredAlert(_ alert: ChannelConditionRequiredView,
                                              didSelectGetTokensFor condition: ErmisChat.ChannelConditionPayload) {
        guard let url = URL(string: condition.linkToPurchase) else {
            return
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
// MARK: - PinnedMessageViewDelegate
extension ChannelViewController: PinnedMessageViewDelegate {
    public func pinnedMessageViewDidSelected(_ pinnedMessageView: PinnedMessageView) {
        guard let channel = channelController.channel,
              let messageId = channel.pinnedMessages.last?.id else {
            return
        }
        jumpToMessage(id: messageId, shouldHighlight: true)
    }

    public func pinnedMessageViewDidSelectedUnpinButton(_ pinnedMessageView: PinnedMessageView) {
        unpinLastPinnedMessage()
    }

    public func pinnedMessageViewDidSelectedShowInChatButton(_ pinnedMessageView: PinnedMessageView) {
        guard let channel = channelController.channel,
              let messageId = channel.pinnedMessages.last?.id else {
            return
        }
        jumpToMessage(id: messageId, shouldHighlight: true)
    }

    public func pinnedMessageViewDidSelectedExpandButton(_ pinnedMessageView: PinnedMessageView) {
        showPinnedMessageList()
    }
}
// MARK: - PinnedMessageViewControllerDelegate
extension ChannelViewController: PinnedMessageViewControllerDelegate {
    public func pinnedMessageViewController(_ pinnedMessageViewController: PinnedMessagesViewController, didSelected pinnedMessage: ChatMessage) {
        jumpToMessage(id: pinnedMessage.id, shouldHighlight: true)
    }
}
