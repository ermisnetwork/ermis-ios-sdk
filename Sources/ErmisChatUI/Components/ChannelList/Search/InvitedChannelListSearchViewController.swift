//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// An abstract class responsible to handle the channel list search logic.
/// It is a subclass of the Channel List since most of the logic is reused from the original Channel List.
@available(iOSApplicationExtension, unavailable)
open class InvitedChannelListSearchViewController: InvitedChannelListViewController, UISearchResultsUpdating {
    /// The current active search text.
    public var currentSearchText: String = ""

    override open var isChannelListStatesEnabled: Bool {
        false
    }

    // MARK: - Lifecycle

    override open func setUpUI() {
        super.setUpUI()

        view.embed(emptyView)
        emptyView.isHidden = true
        emptyView.actionButton.removeFromSuperview()
        emptyView.titleLabel.isHidden = true
    }

    override open func setUp() {
        collectionView.register(
            components.invitedChannelCell,
            forCellWithReuseIdentifier: components.invitedChannelCell.reuseIdentifier
        )

        collectionView.register(
            components.channelCellSeparator,
            forSupplementaryViewOfKind: ListCollectionViewLayout.separatorKind,
            withReuseIdentifier: separatorReuseIdentifier
        )

        collectionView.delegate = self
        setupDiffableDataSource()
    }

    override open func setUpTheme() {
        super.setUpTheme()

        emptyView.iconView.image = theme.icons.emptySearch
    }

    open override func shouldShowEmptyView() -> Bool {
        return channels.isEmpty
    }
    
    open override func buildSnapshot(from channels: [Channel]) -> NSDiffableDataSourceSnapshot<String, Channel> {
        let predicate = NSPredicate(format: "SELF CONTAINS[cd] %@", self.currentSearchText)
        let filteredChannels: [Channel] = channels.filter { self.currentSearchText.isEmpty ? true : predicate.evaluate(with: $0.directUserMembership?.displayName) }
        return super.buildSnapshot(from: filteredChannels)
    }


    // MARK: - UISearchResultsUpdating

    open func updateSearchResults(for searchController: UISearchController) {
        guard let text = searchController.searchBar.text, !text.isEmpty, text != currentSearchText else {
            return
        }

        currentSearchText = text

        reloadChannels { [weak self] in
            guard let self else {
                return
            }
            emptyView.subtitleLabel.text = currentSearchText.isEmpty ? "" : L10n.ChannelList.Search.Empty.subtitle("\"\(currentSearchText)\"")
            emptyView.isHidden = !shouldShowEmptyView()
        }
    }
    // swiftlint:enable unavailable_function

    // MARK: - State Handling

    open override func handleStateChanges(_ newState: DataController.State) {
        super.handleStateChanges(newState)

        switch newState {
        case .initialized, .localDataFetched:
            loadingIndicator.stopAnimating()
        case .remoteDataFetched:
            loadingIndicator.stopAnimating()
            emptyView.subtitleLabel.text = L10n.ChannelList.Search.Empty.subtitle("\"\(currentSearchText)\"")
            emptyView.isHidden = !shouldShowEmptyView()
        default:
            loadingIndicator.stopAnimating()
        }
    }
}
