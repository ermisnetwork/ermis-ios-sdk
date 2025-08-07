//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view controller responsible to search channels.
/// It implements the required functions of the `ChannelListSearchViewController` abstract class.
@available(iOSApplicationExtension, unavailable)
open class ContactSearchViewController: ContactListSearchViewController {
    /// The closure that is triggered whenever a channel is selected from the search result.
    public var didSelectChannel: ((Channel) -> Void)?

    // MARK: - ChannelListSearchViewController Abstract Implementations

    override open var hasEmptyResults: Bool {
        contacts.isEmpty
    }

    override open func loadSearchResults(with text: String) {
        guard let currentUserId = controller.client.currentUserId else { return }

        replaceQuery(.init(
            filter: .searchDirectChannels(searchText: text,
                                          memberId: currentUserId,
                                          projectId: controller.client.projectId)
        ))
    }

    override open func loadMoreSearchResults() {
        loadMoreChannels()
    }

    // MARK: - Collection View Implementations

    override open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard let channel = getChannel(at: indexPath) else { return }
        didSelectChannel?(channel)
    }
}

