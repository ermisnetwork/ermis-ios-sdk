//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

/// This view controller will show all direct channel of user.
open
class ContactListViewController: ChannelListViewController, UICollectionViewDelegateFlowLayout {
    /// Reuse identifier of collection view header.
    open var collectionViewHeaderReuseIdentifier: String { String(describing: ContactListSectionHeader.self) }

    open lazy var _emptyView: ChannelListEmptyView = components
        .contactListEmptyView.init()
        .withoutAutoresizingMaskConstraints

    open
    override var emptyView: ChannelListEmptyView {
        get {
            return _emptyView
        }
        set {
            _emptyView = newValue
        }
    }

    open override var isChannelListStatesEnabled: Bool {
        return true
    }

    public
    var contacts: [ContactListSection] = []

    // MARK: - Setup
    open override func setUp() {
        super.setUp()
        collectionView.register(components.contactListSectionHeader.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: collectionViewHeaderReuseIdentifier)
        collectionView.register(components.contactListCell,
                                forCellWithReuseIdentifier: components.contactListCell.reuseIdentifier)
        navigationItem.leftBarButtonItems = []
        
        let searchType = components.contactlistSearchType
        let searchController = searchType?.makeSearchController(with: self)
        navigationItem.searchController = searchController
        navigationItem.searchController?.searchBar.placeholder = L10n.ChannelList.search
    }
    // MARK: -

    open override func buildSnapshot(from channels: [Channel]) -> NSDiffableDataSourceSnapshot<String, Channel> {
        let newChannels = Array(controller.channels).sorted(by: {
            let lLastMessageAt = $0.lastMessageAt ?? $0.updatedAt
            let rLastMessageAt = $1.lastMessageAt ?? $1.updatedAt
            return lLastMessageAt > rLastMessageAt
        })

        let newContacts = newChannels.reduce(into: [String:[Channel]]()) { partialResult, channel in
            let channelName = channel.directUserMembership?.displayName ?? channel.cid.rawValue
            let firstCharacter = channelName.first?.uppercased() ?? " "
            if partialResult[firstCharacter] == nil {
                partialResult[firstCharacter] = []
            }
            partialResult[firstCharacter]?.append(channel)
        }

        self.contacts = []
        var snapshot = NSDiffableDataSourceSnapshot<String, Channel>()

        for key in newContacts.keys.sorted() {
            self.contacts.append(.init(title: key, channels: newContacts[key] ?? []))
            snapshot.appendSections([key])
            snapshot.appendItems(newContacts[key] ?? [], toSection: key)
        }

        return snapshot

    }

    open
    override func getChannel(at indexPath: IndexPath) -> Channel? {
        return contacts[safe: indexPath.section]?.channels[safe: indexPath.row]
    }

    // MARK: - Collection
    open func numberOfSections(in collectionView: UICollectionView) -> Int {
        return contacts.count
    }

    open
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let section = contacts[section]
        return section.channels.count
    }

    open override func cellItem(for collectionView: UICollectionView, indexPath: IndexPath, channel: Channel) -> UICollectionViewCell? {
        let cell = collectionView.dequeueReusableCell(with: components.contactListCell, for: indexPath)

        cell.itemView.content = .init(
            channel: channel,
            currentUserId: controller.client.currentUserId
        )

        return cell
    }

    open override func supplementaryView(for collectionView: UICollectionView, _ kind: String, _ indexPath: IndexPath) -> UICollectionReusableView? {
        switch kind {
        case UICollectionView.elementKindSectionHeader:
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                         withReuseIdentifier: collectionViewHeaderReuseIdentifier,
                                                                         for: indexPath)
            if let header = header as? ContactListSectionHeader {
                header.content = contacts[indexPath.section]
            }

            return header
        default:
            return super.collectionView(collectionView, viewForSupplementaryElementOfKind: kind, at: indexPath)
        }
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 64)
    }
}


public
struct ContactListSection {
    public let title: String

    public let channels: [Channel]
}
