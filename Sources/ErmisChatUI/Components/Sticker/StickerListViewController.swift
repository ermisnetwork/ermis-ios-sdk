//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit
import WebKit
import Lottie
import zlib

fileprivate typealias ShowImageTask = _Concurrency.Task<Void, Never>?

public protocol StickerListViewControllerDelegate: AnyObject {
    func stickerListViewController(_ viewController: StickerListViewController,
                                   didSelectStickerURL url: URL)
}

open class StickerListViewController: _ViewController, UIProvider, UICollectionViewDelegateFlowLayout, StickerControllerDelegate, SickerHeaderViewDelegate {
    public var controller: StickerController!

    /// DiffirenceDataSource
    public var dataSource: UICollectionViewDiffableDataSource<String, Item>?

    open private(set) lazy var headerView = components.stickerHeaderView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "headerView")

    open private(set) lazy var collectionView = createCollectionView()

    public weak var delegate: StickerListViewControllerDelegate?

    /// Flag to check when sticker list is reloading or not.
    private(set) var isReloadingStickers = false
    /// Has pending reload sticker list or not, if has reloaded sticker list.
    private var hasPendingReloadStickers = false
    /// When set to `true`, the header’s selected index will not automatically update to match the current state of the sticker list.
    private var preventUpdateHeaderSelectedIndex: Bool = false

    /// Default cell item size.
    private var cellSize: CGSize = .init(width: 80, height: 80)

    open override func setUp() {
        super.setUp()
        setupDiffableDataSource()
        controller.delegate = self
        controller.synchronize()
        reloadStickers()
        headerView.delegate = self
    }

    open override func setUpUI() {
        super.setUpUI()
        view.addSubviews([
            headerView,
            collectionView
        ])

        headerView.pin(anchors: [.top], to: self.view)
        headerView.pin(anchors: [.leading], to: self.view.safeAreaLayoutGuide, constant: 16)
        headerView.pin(anchors: [.trailing], to: self.view.safeAreaLayoutGuide, constant: -16)
        headerView.pin(anchors: [.height], to: 45)
        collectionView.topAnchor.pin(equalTo: headerView.bottomAnchor).isActive = true
        collectionView.pin(anchors: [.bottom], to: self.view)
        collectionView.pin(anchors: [.leading], to: self.view.safeAreaLayoutGuide, constant: 16)
        collectionView.pin(anchors: [.trailing], to: self.view.safeAreaLayoutGuide, constant: -16)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        self.view.backgroundColor = theme.colors.surface
        self.collectionView.backgroundColor = theme.colors.surface
    }

    /// Update sticker list with lastest state from `controller`
    open func reloadStickers(completion: (() -> Void)? = nil) {
        reCalculateCellSize()
        guard !isReloadingStickers else {
            hasPendingReloadStickers = true
            return
        }

        isReloadingStickers = true
        let newStickerPacks = Array(controller.stickerPacks)
        var snapshot = buildSnapshot(from: newStickerPacks)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource?.apply(snapshot, animatingDifferences: true) { [weak self] in
            guard let self else {
                return
            }
            self.isReloadingStickers = false

            if hasPendingReloadStickers {
                hasPendingReloadStickers = false
                reloadStickers(completion: completion)
            } else {
                completion?()
                onStickerReloaded()
            }
        }
    }
    
    open func onStickerReloaded() {
        reloadHeaderView()
    }

    /// Build data source snapshot for collection view.
    open func buildSnapshot(from stickerPacks: [StickerPack]) -> NSDiffableDataSourceSnapshot<String , Item> {
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        snapshot.appendSections(stickerPacks.map { $0.id})
        for stickerPack in stickerPacks {
            snapshot.appendItems(stickerPack.stickers.map { .init(sectionId: stickerPack.id, sticker: $0) }, toSection: stickerPack.id)
        }
        return snapshot
    }
    /// Reload menu header.
    open func reloadHeaderView() {
        guard let snapshot = dataSource?.snapshot() else {
            headerView.content = []
            return
        }

        var stickerPackHeaders = snapshot.sectionIdentifiers.compactMap { section in
            let items = snapshot.itemIdentifiers(inSection: section)
            return items.first
        }

        headerView.content = stickerPackHeaders
    }
    // MARK: - UICollectionView
    /// Setup UICollectionViewDiffableDataSource
    public func setupDiffableDataSource() {
        dataSource = UICollectionViewDiffableDataSource<String, Item>(collectionView: collectionView, cellProvider: { [weak self] collectionView, indexPath, item in
            guard let self else {
                return nil
            }

            return self.cellItem(for: collectionView, indexPath: indexPath, sticker: item.sticker)
        })

        dataSource?.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            return self?.supplementaryView(for: collectionView, kind, indexPath)
        }
    }

    /// Get cell item of UICollectionView at indexPath.
    ///  - Parameters:
    ///   - collectionView: The `UICollectionView` instance.
    ///   - indexPath: The indexPath of the cell
    ///   - sticker: The Sticker at that indexPath
    ///  - Returns: The `UICollectionViewCell` at indexPath
    open func cellItem(for collectionView: UICollectionView,
                       indexPath: IndexPath,
                       sticker: Sticker) -> UICollectionViewCell? {
        let cell = collectionView.dequeueReusableCell(with: components.stickerCell, for: indexPath)

        cell.itemView.content = sticker

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
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                     withReuseIdentifier: String(describing: components.stickerPackTitleHeader),
                                                                     for: indexPath) as? StickerPackTitleHeaderView
        if let packId = dataSource?.sectionIdentifier(for: indexPath.section),
           let pack = Array(controller.stickerPacks).first(where: { $0.id == packId}) {
            header?.titleLabel.text = pack.title
        }
        return header
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 40)
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return cellSize
    }

    open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let sticker = sticker(at: indexPath),
              let urlString = sticker.url,
              let url = URL(string: urlString) else {
            return
        }

        controller.addRecentSticker(sticker)
        delegate?.stickerListViewController(self, didSelectStickerURL: url)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let collectionView = scrollView as? UICollectionView else { return }
        guard !preventUpdateHeaderSelectedIndex else {
            return
        }
        // Find the top-most visible item
        if let indexPath = collectionView.indexPathsForVisibleItems.min(by: { $0.item < $1.item }) {
            if headerView.selectedIndex != indexPath.section {
                headerView.setSelectedIndex(indexPath.section)
            }
        }
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if preventUpdateHeaderSelectedIndex {
            preventUpdateHeaderSelectedIndex.toggle()
        }
    }

    /// Calculate item size for collectionView.
    public func reCalculateCellSize() {
        let expectedSize = 80
        let width = view.bounds.width - 32 - view.safeAreaInsets.left - view.safeAreaInsets.right
        let itemMinSpacing = 5
        let idealNumberOfItemsPerRow = Int(round(width / CGFloat(expectedSize)))
        let numberOfItem = max(4, idealNumberOfItemsPerRow)
        let size = floor((width - CGFloat(numberOfItem * itemMinSpacing)) / CGFloat(numberOfItem))
        cellSize = CGSize(width: size, height: size)
    }

    // MARK: - Helper
    private func sticker(at indexPath: IndexPath) -> Sticker? {
        guard let dataSource = dataSource else {
            return nil
        }
        return dataSource.itemIdentifier(for: indexPath)?.sticker
    }

    /// Scrolls the collection view to a specific section.
    /// - Parameter index: The index of the section to scroll to.
    private func scrollToSection(at index: Int) {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            return
        }
        let headerIndexPath = IndexPath(item: 0, section: index)
        if let headerAttributes = layout.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: headerIndexPath
        ) {
            let offset = CGPoint(x: 0, y: headerAttributes.frame.origin.y - collectionView.contentInset.top)
            collectionView.setContentOffset(offset, animated: true)
        }
    }
    // MARK: - StickerControllerDelegate
    public func controller(_ controller: StickerController, didChangeStickerPacks changes: [ListChange<StickerPack>]) {
        reloadStickers()
    }

    public func controllerWillChangeStickerPack(_ controller: StickerController) {
        collectionView.layoutIfNeeded()
    }

    public func stickerHeaderView(_ view: StickerHeaderView, didSelect item: Item) {
        if let indexPath = dataSource?.indexPath(for: item) {
            preventUpdateHeaderSelectedIndex = true
            scrollToSection(at: indexPath.section)
        }
    }
    // MARK: - Create UI
    open func createCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 5
        layout.minimumInteritemSpacing = 5
        layout.scrollDirection = .vertical
        let collectionView = UICollectionView(frame: UIScreen.main.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.register(components.stickerCell)
        collectionView.register(components.stickerPackTitleHeader,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: String(describing: components.stickerPackTitleHeader))
        collectionView.showsVerticalScrollIndicator = false
        return collectionView
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "collectionView")
    }

    
}
// MARK: - Item
extension StickerListViewController {
    // Represent item for data souce
    public struct Item: Hashable {
        let sectionId: String
        let sticker: Sticker

        public func hash(into hasher: inout Hasher) {
            hasher.combine(sectionId)
            hasher.combine(sticker.id)
        }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            return lhs.sectionId == rhs.sectionId &&
            lhs.sticker == rhs.sticker
        }
    }
}
