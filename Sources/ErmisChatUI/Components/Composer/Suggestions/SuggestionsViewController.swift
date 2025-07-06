//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view controller that shows suggestions of commands or mentions.
open class SuggestionsViewController: _ViewController,
                                      UIProvider,
                                      UICollectionViewDelegate {
    /// The data provider of the collection view. A custom `UICollectionViewDataSource` can be provided,
    /// by default `MessageComposerSuggestionsCommandDataSource` is used.
    /// A subclass of `MessageComposerSuggestionsCommandDataSource` can also be provided.
    public var dataSource: UICollectionViewDataSource? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The number of visible commands without scrolling.
    open var numberOfVisibleRows: CGFloat = 4

    /// A closure to observer when an item is selected.
    public var didSelectItemAt: ((Int) -> Void)?

    /// Property to check if the suggestions view controller is currently presented.
    public var isPresented: Bool {
        view.superview != nil
    }

    /// The collection view of the commands.
    open private(set) lazy var collectionView: SuggestionsCollectionView = components
        .suggestionsCollectionView
        .init(layout: components.suggestionsCollectionViewLayout.init())
        .withoutAutoresizingMaskConstraints

    /// The container view where collectionView is embedded.
    open private(set) lazy var containerView: UIView = UIView().withoutAutoresizingMaskConstraints

    // Height for suggestion cell, this value should never be 0
    // otherwise it causes loop for height of this controller and as a result this controller height will be 0 as well.
    // Note: This value can be 1, it's just for purpose of 1 cell being visible.
    private let defaultRowHeight: CGFloat = 44

    /// The constraints responsible for setting the height of the main view.
    public lazy var heightConstraints: NSLayoutConstraint = {
        let constraint = view.heightAnchor.pin(equalToConstant: 0)
        constraint.isActive = true
        return constraint
    }()

    private var collectionViewHeightObserver: NSKeyValueObservation?

    override open func setUp() {
        super.setUp()

        collectionView.delegate = self
    }

    override open func setUpTheme() {
        super.setUpTheme()
        view.backgroundColor = .clear
        view.layer.addShadow(color: theme.colors.outline)
    }

    override open func setUpUI() {
        view.embed(containerView)
        containerView.embed(
            collectionView,
            insets: .init(
                top: 0,
                leading: containerView.directionalLayoutMargins.leading,
                bottom: 0,
                trailing: containerView.directionalLayoutMargins.trailing
            )
        )

        collectionViewHeightObserver = collectionView.observe(
            \.contentSize,
            options: [.new],
            changeHandler: { [weak self] collectionView, change in
                guard let self = self, let newSize = change.newValue else { return }

                // NOTE: The defaultRowHeight height value will be used only once to set visibleCells
                // once again, not looping it to 0 value so this controller can resize again.
                let cellHeight = collectionView.visibleCells.first?.bounds.height ?? self.defaultRowHeight

                let newHeight = min(newSize.height, cellHeight * self.numberOfVisibleRows)
                self.heightConstraints.constant = newHeight
            }
        )
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        collectionView.dataSource = dataSource
        collectionView.reloadData()
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        didSelectItemAt?(indexPath.row)
    }
}

open class MessageComposerSuggestionsCommandDataSource: NSObject, UICollectionViewDataSource {
    open var collectionView: SuggestionsCollectionView

    /// The list of commands.
    open var commands: [Command]

    /// The current types to override ui components.
    open var components: Components {
        collectionView.components
    }

    /// The current types to override ui components.
    open var theme: Theme {
        collectionView.theme
    }

    /// Data Source Initialiser
    ///
    /// - Parameters:
    ///   - commands: The list of commands.
    ///   - collectionView: The collection view of the commands.
    public init(with commands: [Command], collectionView: SuggestionsCollectionView) {
        self.commands = commands
        self.collectionView = collectionView

        super.init()

        registerCollectionViewCell()

        collectionView.register(
            SuggestionsCollectionReusableView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "CommandsHeader"
        )
        (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?
            .headerReferenceSize = CGSize(width: self.collectionView.frame.size.width, height: 40)
    }

    private func registerCollectionViewCell() {
        collectionView.register(
            components.suggestionsCommandCollectionViewCell,
            forCellWithReuseIdentifier: components.suggestionsCommandCollectionViewCell.reuseId
        )
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard let headerView = collectionView.dequeueReusableSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "CommandsHeader",
            for: indexPath
        ) as? SuggestionsCollectionReusableView else {
            return UICollectionReusableView()
        }

        headerView.suggestionsHeader.headerLabel.text = L10n.Composer.Suggestions.Commands.header
        headerView.suggestionsHeader.commandImageView.image = theme.icons.commands
            .tinted(with: headerView.tintColor)

        return headerView
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        commands.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(with: CommandSuggestionCollectionViewCell.self, for: indexPath)

        guard let command = commands[safe: indexPath.row] else {
            indexNotFoundAssertion()
            return cell
        }

        cell.commandView.content = command

        return cell
    }
}

open class MessageComposerSuggestionsMentionDataSource: NSObject,
    UICollectionViewDataSource,
    UserSearchControllerDelegate,
    ChannelMemberListControllerDelegate {
    /// The current users mentions.
    private(set) var users: [ChatUser]

    private(set) var mentionedAll: Bool

    /// The collection view of the mentions.
    open var collectionView: SuggestionsCollectionView

    /// The search controller to search for mentions across the whole app.
    open var searchController: UserSearchController

    /// The member list controller to search for users inside a channel.
    open var memberListController: ChannelMemberListController?

    /// The types to override ui components.
    var components: Components {
        collectionView.components
    }

    /// Data Source Initialiser
    /// - Parameters:
    ///   - collectionView: The collection view of the mentions.
    ///   - searchController: The search controller to find mentions.
    ///   - memberListController: The member list controller to search for users inside a channel.
    ///   - usersCache: The initial results.
    init(
        collectionView: SuggestionsCollectionView,
        searchController: UserSearchController,
        memberListController: ChannelMemberListController?,
        initialUsers: [ChatUser],
        isMentionedAll: Bool
    ) {
        self.collectionView = collectionView
        self.searchController = searchController
        self.memberListController = memberListController
        users = initialUsers.sorted(by: { ($0.name ?? $0.userId) < ($1.name ?? $1.userId) })
        self.mentionedAll = isMentionedAll
        super.init()
        registerCollectionViewCell()
        (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?
            .headerReferenceSize = CGSize(width: self.collectionView.frame.size.width, height: 0)
        searchController.delegate = self
        memberListController?.delegate = self
    }

    private func registerCollectionViewCell() {
        collectionView.register(
            components.suggestionsMentionCollectionViewCell,
            forCellWithReuseIdentifier: components.suggestionsMentionCollectionViewCell.reuseId
        )
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        UICollectionReusableView()
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        mentionedAll ? users.count + 1 : users.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(with: MentionSuggestionCollectionViewCell.self, for: indexPath)

        if mentionedAll, indexPath.row == 0 {
            cell.mentionView.content = .allUser
            return cell
        }

        guard let user = mentionedAll ? users[safe: indexPath.row - 1] : users[safe: indexPath.row] else {
            indexNotFoundAssertion()
            return cell
        }
        // We need to make sure we set the components before accessing the mentionView,
        // so the mentionView is created with the most up-to-dated components.
        cell.mentionView.content = .mention(user)
        return cell
    }

    public func controller(
        _ controller: UserSearchController,
        didChangeUsers changes: [ListChange<ChatUser>]
    ) {
        //users = searchController.users
        collectionView.reloadData()
    }

    public func memberListController(
        _ controller: ChannelMemberListController,
        didChangeMembers changes: [ListChange<ChannelMember>]
    ) {
        users = Array(controller.members.filter({ $0.memberRole != .pending }))
        collectionView.reloadData()
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        if let memberListController = controller as? ChannelMemberListController {
            users = Array(memberListController.members)
            collectionView.reloadData()
        }
    }
}
