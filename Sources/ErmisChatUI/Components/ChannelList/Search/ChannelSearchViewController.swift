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

    override open func loadSearchResults(with text: String) {
        super.loadSearchResults(with: text)
    }

    override open func loadMoreSearchResults() {
        loadMoreChannels()
    }

    // MARK: - Collection View Implementations

    open override func cellItem(for collectionView: UICollectionView, indexPath: IndexPath, channel: Channel) -> UICollectionViewCell? {
        let cell = collectionView.dequeueReusableCell(with: components.channelListCell, for: indexPath)

        guard let channelListCell = cell as? ChannelListCollectionViewCell else {
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
