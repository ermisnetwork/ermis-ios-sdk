//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view controller responsible to search channels.
/// It implements the required functions of the `ChannelListSearchViewController` abstract class.
@available(iOSApplicationExtension, unavailable)
open class ChannelSearchViewController: ChannelListSearchViewController {
    /// The closure that is triggered whenever a channel is selected from the search result.
    public var didSelectChannel: ((Channel) -> Void)?

    // MARK: - ChannelListSearchViewController Abstract Implementations

    override open var hasEmptyResults: Bool {
        channels.isEmpty
    }

    override open func loadSearchResults(with text: String) {
        guard let currentUserId = controller.client.currentUserId else { return }

        replaceQuery(.init(
            filter: .and([
                .autocomplete(.name, text: text),
                .or([
                    .joinedChannels(memberId: currentUserId,
                                    projectId: controller.client.projectId),
                    .publicChannel(projectId: controller.client.projectId)
                ])

            ])
        ))
    }

    override open func loadMoreSearchResults() {
        loadMoreChannels()
    }

    // MARK: - Collection View Implementations

    override open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = super.collectionView(collectionView, cellForItemAt: indexPath)
        guard let channelListCell = cell as? ChannelListCollectionViewCell,
              let channel = channelListCell.itemView.content?.channel else {
            return cell
        }

        channelListCell.itemView.content = .init(
            channel: channel,
            currentUserId: controller.client.currentUserId,
            searchResult: .init(text: currentSearchText, message: nil)
        )

        return channelListCell
    }

    override open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard let channel = channels[safe: indexPath.row] else { return }
        didSelectChannel?(channel)
    }
}
