//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit
import Combine

@available(iOSApplicationExtension, unavailable)
open class TopicListViewController: _ViewController,
                                    UICollectionViewDelegate,
                                    ChannelListControllerDelegate,
                                    UIProvider,
                                    SwipeableViewDelegate {

    /// The data of the channel list.
    public var channels: [Channel] {
        return dataSource?.snapshot().itemIdentifiers ?? []
    }

    /// DiffirenceDataSource
    public var dataSource: UICollectionViewDiffableDataSource<String, Channel>?

    /// The `ChannelListController` instance that provides channels data.
    public var controller: ChannelListController!

    /// The `Channel controller` instance that provide channel data
    public var channelController: ChannelController?

    /// A boolean value that determines if the chat channel list view states are shown and handled by the SDK.
    open var isChannelListStatesEnabled: Bool {
        components.isChannelListStatesEnabled
    }

    open private(set) lazy var loadingIndicator: UIActivityIndicatorView = {
        return UIActivityIndicatorView(
            style: .large
        ).withoutAutoresizingMaskConstraints

    }()
    
    /// A router object responsible for handling navigation actions of this view controller.
    open lazy var router: TopicListRouter = components
        .topicListRouter
        .init(rootViewController: self)

    /// The `UICollectionViewLayout` that used by `ChannelListCollectionView`.
    open private(
        set
    ) lazy var collectionViewLayout: UICollectionViewLayout = components
        .topicListLayout.init()

    /// The `UICollectionView` instance that displays topic list.
    open private(set) lazy var collectionView: UICollectionView =
    UICollectionView(frame: .zero, collectionViewLayout: collectionViewLayout)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "collectionView")

    /// The view that is displayed when there are no topics on the list, i.e. when is on empty state.
    open private(set) lazy var emptyView: TopicListEmptyView = {
        components.topicListEmptyView.init()
            .withoutAutoresizingMaskConstraints
    }()
    
    /// View which will be shown at the bottom when an error occurs when fetching either local or remote topic.
    /// This view has an action to retry the channel loading.
    open private(set) lazy var topicListErrorView: TopicListErrorView = {
        let view = components.topicListErrorView.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    /// View that shows when loading the Topic list.
    open private(
        set
    ) lazy var topicListLoadingView: TopicListLoadingView = components
        .topicListLoadingView
        .init()
        .withoutAutoresizingMaskConstraints

    /// Header View
    open private(set) lazy var headerView: ChannelHeaderView = components
        .channelHeaderView.init()
        .withoutAutoresizingMaskConstraints
    
    /// The `OngoingCallView` instance show when have ongoing call.
    open private(set) lazy var ongoingCallView = components
        .ongoingCallVIew
        .init()
        .withoutAutoresizingMaskConstraints

    open var shouldShowOngoingCallView: Bool {
        return false
    }

    /// Reuse identifier of separator
    open var separatorReuseIdentifier: String { "CellSeparatorIdentifier" }

    /// Currently there are some performance problems in the Channel List which
    /// is impacting the message list performance as well, so we skip channel list
    /// updates when the channel list is not visible in the window.
    private(set) var skippedRendering = false
    private(set) var skipChannelUpdates = true
    /// Flag to check when channel list is reloading or not.
    private(set) var isReloadingChannelList = false
    /// Has pending reload channel list or not, if has continue reload.
    private var hasPendingReloadChannels = false

    /// List of user has fetch info
    private var userIdsHasFetchedInfo: Set<String> = []
    ///
    private var isFetchingMissingUserInfo: Bool = false

    private lazy var cancelBags: Set<AnyCancellable> = []
    
    /// Create a new `TopicListViewController`
    /// - Parameters:
    ///   - controller: Your created `TopicListViewController` with required query
    ///   - storyboard: The storyboard to instantiate your `ViewController` from
    ///   - storyboardId: The `storyboardId` that is set in your `UIStoryboard` reference
    /// - Returns: A newly created `TopicListViewController`
    public static func make(
        with controller: ChannelListController,
        storyboard: UIStoryboard? = nil,
        storyboardId: String? = nil
    ) -> Self {
        var channelListVC: Self!

        // Check if we have a UIStoryboard and/or StoryboardId
        if let storyboardId = storyboardId, let storyboard = storyboard {
            // Safely unwrap the ViewController from the Storyboard
            guard let localViewControllerFromStoryboard = storyboard
                .instantiateViewController(withIdentifier: storyboardId) as? Self else {
                fatalError(
                    "Failed to load from UIStoryboard, please check your storyboardId and/or UIStoryboard reference."
                )
            }
            channelListVC = localViewControllerFromStoryboard
        } else {
            channelListVC = Self()
        }

        // Set the Controller on the ViewController
        channelListVC.controller = controller
        if let parentCid = controller.parentCid {
            channelListVC.channelController = controller.client.channelController(for: parentCid)
        } else {
            log.warning("[Topic List] Parent CID is nil")
        }
        // Return the newly created ChannelListViewController
        return channelListVC
    }
    
    override open func setUp() {
        super.setUp()
        setupDiffableDataSource()
        controller.delegate = self
        controller.synchronize()
        
        collectionView.register(
            components.topicListCell.self,
            forCellWithReuseIdentifier: components.topicListCell.reuseIdentifier
        )

        collectionView.register(
            components.topicCellSeparator,
            forSupplementaryViewOfKind: ListCollectionViewLayout.separatorKind,
            withReuseIdentifier: separatorReuseIdentifier
        )

        collectionView.delegate = self

        topicListErrorView.refreshButtonAction = { [weak self] in
            self?.controller.synchronize()
            self?.topicListErrorView.hide()
        }

    
        navigationItem.backButtonTitle = ""

        if let flowLayout = collectionViewLayout as? ListCollectionViewLayout {
            flowLayout.itemSize = UICollectionViewFlowLayout.automaticSize
            flowLayout.estimatedItemSize = .init(
                width: collectionView.bounds.width,
                height: 64
            )
        }
        
        reloadChannels()

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
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        skipChannelUpdates = false

        if skippedRendering {
            UIView.performWithoutAnimation {
                reloadChannels()
            }
            skippedRendering = false
        }
    }

    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        skipChannelUpdates = true
    }

    open override func viewDidLayoutSubviews() {
        topicListLoadingView.contentDidChanged()
    }

    open func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // no-op
    }
    
    override open func setUpUI() {
        super.setUpUI()
        view.embed(collectionView)

        if isChannelListStatesEnabled {
            view.embed(topicListLoadingView)
            view.embed(emptyView)
            emptyView.isHidden = true
            view.addSubview(topicListErrorView)
            topicListErrorView.pin(anchors: [.leading, .trailing, .bottom], to: view)
            topicListErrorView.hide()
        } else {
            collectionView.addSubview(loadingIndicator)
            loadingIndicator.pin(anchors: [.centerX, .centerY], to: view)
        }

        if let parentCid = controller.parentCid {
            headerView.channelController = channelController
        } else {
            log.warning("[TopicList] Parent CID not set")
        }
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: headerView)
        navigationItem.largeTitleDisplayMode = .never
    }

    override open func setUpTheme() {
        super.setUpTheme()

        collectionView.backgroundColor = theme.colors.surface
    }
    
    /// Replaces the channel list query and loads the new data.
    ///
    /// In case your `ChannelListController` uses a filter block, you should
    /// use the `replaceChannelListController()` function instead of this one.
    ///
    /// - Parameter query: The new channel list query.
    public func replaceQuery(_ query: ChannelListQuery) {
        let newController = controller.client.channelListController(
            query: query
        )
        replaceChannelListController(newController)
    }

    /// Replaces the channel list controller and loads the new data.
    /// - Parameter controller: The new channel list controller.
    public func replaceChannelListController(_ controller: ChannelListController) {
        self.controller = controller
        self.controller.delegate = self
        self.controller.synchronize()
        reloadChannels()
    }
    
    open func buildSnapshot(from channels: [Channel]) -> NSDiffableDataSourceSnapshot<String , Channel> {
        var snapshot = NSDiffableDataSourceSnapshot<String, Channel>()
        snapshot.appendSections(["all"])
        snapshot.appendItems(channels, toSection: "all")
        return snapshot
    }

    
    /// Updates the list view with the most updated channels.
    open func reloadChannels(completion: (() -> Void)? = nil) {
        guard !isReloadingChannelList else {
            hasPendingReloadChannels = true
            return
        }

        isReloadingChannelList = true
        let newChannels = Array(controller.channels)
        var snapshot = buildSnapshot(from: newChannels)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource?.apply(snapshot, animatingDifferences: true) { [weak self] in
            guard let self else {
                return
            }
            let snapshot = self.dataSource?.snapshot() ?? snapshot

            self.isReloadingChannelList = false

            if hasPendingReloadChannels {
                hasPendingReloadChannels = false
                reloadChannels(completion: completion)
            } else {
                completion?()
                onChannelReloaded()
            }
        }
    }

    
    open func onChannelReloaded() {
        // Implement on subclass.
    }
    
    public func setOngoingCallViewHidden(_ isHidden: Bool) {
        guard shouldShowOngoingCallView else {
            return
        }

        if ongoingCallView.superview == nil {
            self.view.addSubview(ongoingCallView)
            ongoingCallView.pin(anchors: [.top, .leading, .trailing], to: view.safeAreaLayoutGuide)
        }

        ongoingCallView.isHidden = isHidden
        collectionView.contentInset.top = isHidden ? 0 : 32
    }
    /// Condition to show emptyView or not
    open func shouldShowEmptyView() -> Bool {
        return controller.channels.isEmpty
    }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        collectionViewLayout.invalidateLayout()

        // Required to correctly setup navigation when view is wrapped
        // using UIHostingController and used in SwiftUI
        guard
            let parent = parent,
            parent.isUIHostingController
        else { return }
        setupParentNavigation(parent: parent)
    }
    
    open
    func closed() {
        navigationController?.popViewController(animated: true)
    }
    // MARK: - Collection View
    /// Setup UICollectionViewDiffableDataSource
    public func setupDiffableDataSource() {
        dataSource = UICollectionViewDiffableDataSource<String, Channel>(collectionView: collectionView, cellProvider: { [weak self] collectionView, indexPath, channel in
            guard let self else {
                return UICollectionViewCell()
            }

            return self.cellItem(for: collectionView, indexPath: indexPath, channel: channel)
        })

        dataSource?.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            return self?.supplementaryView(for: collectionView, kind, indexPath)
        }
    }

    /// Get cell item of UICollectionView at indexPath.
    ///  - Parameters:
    ///   - collectionView: The `UICollectionView` instance.
    ///   - indexPath: The indexPath of the cell
    ///   - channel: The channel at that indexPath
    ///  - Returns: The `UICollectionViewCell` at indexPath
    open func cellItem(for collectionView: UICollectionView,
                       indexPath: IndexPath,
                       channel: Channel) -> UICollectionViewCell? {
        let cell = collectionView.dequeueReusableCell(with: components.topicListCell, for: indexPath)

        cell.itemView.content = .init(
            channel: channel,
            currentUserId: controller.client.currentUserId,
            searchResult: nil
        )

        cell.swipeableView.delegate = self
        cell.swipeableView.indexPath = { [weak cell, weak self] in
            guard let cell = cell else { return nil }
            return self?.collectionView.indexPath(for: cell)
        }

        return cell
    }

    /// Get supplimentaryView  of UICollectionView at indexPath
    ///  - Parameters:
    ///   - collectionView: The `UICollectionView` instance.
    ///   - kind: The supplementary view kind
    ///   - indexPath: The indexPath of the cell
    ///  - Returns: The `UICollectionReusableView` at indexPath
    open func supplementaryView(for collectionView: UICollectionView,
                                _ kind: String,
                                _ indexPath: IndexPath) -> UICollectionReusableView? {
        collectionView.dequeueReusableSupplementaryView(
            ofKind: ListCollectionViewLayout.separatorKind,
            withReuseIdentifier: separatorReuseIdentifier,
            for: indexPath
        )
    }
    
    open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        channels.count
    }

    open func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        collectionView.dequeueReusableSupplementaryView(
            ofKind: ListCollectionViewLayout.separatorKind,
            withReuseIdentifier: separatorReuseIdentifier,
            for: indexPath
        )
    }
    
    // MARK: - User info
    private func getMissingUserIds(of channels: [Channel]) -> [String] {
        var userIds: Set<String> = []
        for channel in channels {
            userIds = userIds.union(channel.lastActiveMembers.map({ $0.userId }))
        }
        userIds = userIds.subtracting(userIdsHasFetchedInfo)
        return Array(userIds)
    }

    private func updateUserMissingInfo(of channels: [Channel]) {
        let ids = getMissingUserIds(of: channels)
        guard !ids.isEmpty, !isFetchingMissingUserInfo else {
            return
        }
        isFetchingMissingUserInfo = true
        controller.client.fetchUsers(with: ids) { [weak self] result in
            switch result {
            case .success:
                self?.userIdsHasFetchedInfo.formUnion(ids)
                DispatchQueue.main.async {
                    self?.reloadChannels()
                }
            case .failure(let error):
                break
            }
            self?.isFetchingMissingUserInfo = false
        }
    }
    
    open func getChannel(at indexPath: IndexPath) -> Channel? {
        let index = indexPath.row
        channels.assertIndexIsPresent(index)
        return channels[safe: index]
    }
    
    // MARK: - SwipeableViewDelegate
    open func swipeableViewWillShowActionViews(for indexPath: IndexPath) {
        // Close other open cells
        collectionView.visibleCells.forEach {
            let cell = ($0 as? TopicListCollectionViewCell)
            cell?.swipeableView.close()
        }

        Animate { self.collectionView.layoutIfNeeded() }
    }

    open func swipeableViewActionViews(for indexPath: IndexPath) -> [UIView] {
        let deleteView = CellActionView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "deleteView")
        deleteView.actionButton.setImage(theme.icons.messageActionDelete, for: .normal)

        deleteView.actionButton.backgroundColor = theme.colors.error
        deleteView.actionButton.tintColor = .white

        deleteView.action = { [weak self] in self?.deleteButtonPressedForCell(at: indexPath) }

        let moreView = CellActionView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "moreView")
        moreView.actionButton.setImage(theme.icons.more, for: .normal)

        moreView.actionButton.backgroundColor = theme.colors.surface
        moreView.actionButton.tintColor = theme.colors.text

        moreView.action = { [weak self] in self?.moreButtonPressedForCell(at: indexPath) }

        if let channel = channels[safe: indexPath.item], channel.canDeleteChannel {
            return [moreView, deleteView]
        }

        return [moreView]
    }

    /// This function is called when delete button is pressed from action items of a cell.
    /// - Parameter indexPath: IndexPath of given cell to fetch the content of it.
    open func deleteButtonPressedForCell(at indexPath: IndexPath) {
        guard let channel = getChannel(at: indexPath) else { return }
        router.didTapDeleteButton(for: channel.cid, parentCid: channel.parentCid)
        closeSwipeableView(at: indexPath)
    }

    /// This function is called when more button is pressed from action items of a cell.
    /// - Parameter indexPath: IndexPath of given cell to fetch the content of it.
    open func moreButtonPressedForCell(at indexPath: IndexPath) {
        guard let channel = getChannel(at: indexPath) else { return }
        router.didTapMoreButton(for: channel.cid, parentCid: channel.parentCid)
        closeSwipeableView(at: indexPath)
    }

    open func closeSwipeableView(at indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) as? TopicListCollectionViewCell {
            cell.swipeableView.close()
        }
    }
    
    open func controllerWillChangeChannels(_ controller: ChannelListController) {
        collectionView.layoutIfNeeded()
    }
    // MARK: - DataControllerStateDelegate

    open func controller(_ controller: DataController, didChangeState state: DataController.State) {
        handleStateChanges(state)
    }

    /// Called whenever the channels data changes or the controller.state changes.
    /// It controls the visibility of the channel list state views.
    open func handleStateChanges(_ newState: DataController.State) {
        if isChannelListStatesEnabled {
            var shouldHideEmptyView = true
            var shouldHideErrorView = true
            var isLoading = true

            switch newState {
            case .initialized:
                isLoading = controller.channels.isEmpty ?? true
            case .localDataFetched:
                reloadChannels()
            case .remoteDataFetched:
                isLoading = false
                shouldHideEmptyView = !shouldShowEmptyView()
                reloadChannels()
                updateUserMissingInfo(of: channels)
            case .localDataFetchFailed, .remoteDataFetchFailed:
                shouldHideEmptyView = !shouldShowEmptyView()
                isLoading = false
                shouldHideErrorView = isChannelListStatesEnabled ? false : true
                topicListErrorView.show()
            }

            emptyView.isHidden = shouldHideEmptyView
            if isLoading, topicListLoadingView.isHidden {
                topicListLoadingView.isHidden = false
            } else if !isLoading, !topicListLoadingView.isHidden {
                topicListLoadingView.isHidden = true
            }
            if shouldHideErrorView {
                topicListErrorView.hide()
            } else {
                topicListErrorView.show()
            }
        } else {
            switch newState {
            case .initialized:
                if controller.channels.isEmpty ?? true {
                    loadingIndicator.startAnimating()
                } else {
                    loadingIndicator.stopAnimating()
                }
            case .localDataFetched:
                reloadChannels()
            case .remoteDataFetched:
                reloadChannels()
                updateUserMissingInfo(of: channels)
                loadingIndicator.stopAnimating()
            default:
                loadingIndicator.stopAnimating()
            }
        }
    }


    @objc(collectionView:cellForItemAtIndexPath:) open func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(with: components.topicListCell, for: indexPath)
        guard let channel = getChannel(at: indexPath) else { return cell }

        cell.itemView.content = .init(
            channel: channel,
            currentUserId: controller.client.currentUserId,
            searchResult: nil
        )
        cell.swipeableView.delegate = self
        cell.swipeableView.indexPath = { [weak cell, weak self] in
            guard let cell = cell else { return nil }
            return self?.collectionView.indexPath(for: cell)
        }

        return cell
    }


    open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard let channel = getChannel(at: indexPath) else { return }
            
        router.showTopic(for: channel.cid, parentCid: channel.parentCid ?? channel.cid)
    }
    
    
    // MARK: - ChannelControllerDelegate
    open func controller(
        _ controller: ChannelListController,
        didChangeChannels changes: [ListChange<Channel>]
    ) {
        if skipChannelUpdates {
            skippedRendering = true
            reloadChannels()
            switch controller.state {
            case .remoteDataFetched:
                emptyView.isVisible = shouldShowEmptyView()
            default:
                break
            }
            return
        }
        handleStateChanges(controller.state)
    }
}
