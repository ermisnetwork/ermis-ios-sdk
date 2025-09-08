//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol SickerHeaderViewDelegate: AnyObject {
    func stickerHeaderView(_ view: StickerHeaderView, didSelect item: StickerListViewController.Item)
}

open class StickerHeaderView: _View, UIProvider, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    open private(set) lazy var collectionView = createCollectionView()

    public weak var delegate: SickerHeaderViewDelegate?

    public var content: [StickerListViewController.Item] = [] {
        didSet {
            updateContentIfNeeded()
        }
    }
    
    var selectedIndex: Int = 0

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        embed(collectionView)
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        collectionView.reloadData()
    }

    open override func setUpTheme() {
        super.setUpTheme()
        self.backgroundColor = theme.colors.surface
        self.collectionView.backgroundColor = theme.colors.surface
    }

    public func setSelectedIndex(_ selectedIndex: Int) {
        guard self.selectedIndex != selectedIndex else { return }
        var visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        visibleIndexPaths.removeFirst()
        visibleIndexPaths.removeLast()

        if !visibleIndexPaths.contains(IndexPath(row: selectedIndex, section: 0)) {
            collectionView.scrollToItem(at: IndexPath(row: selectedIndex, section: 0), at: selectedIndex < self.selectedIndex ? .left : .right, animated: true)
        }
        self.selectedIndex = selectedIndex
        collectionView.reloadData()
    }
    // MARK: - Collection View
    open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return content.count
    }

    open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(with: components.stickerHeaderCell, for: indexPath)
        cell.itemView.content = content[indexPath.row]
        cell.itemView.isSelected = indexPath.row == selectedIndex
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let cell = collectionView.cellForItem(at: IndexPath(row: selectedIndex, section: 0)) as? StickerHeaderCell {
            cell.itemView.isSelected = false
        }
        if let cell = collectionView.cellForItem(at: indexPath) as? StickerHeaderCell {
            cell.itemView.isSelected = true
        }
        self.selectedIndex = indexPath.row
        delegate?.stickerHeaderView(self, didSelect: content[indexPath.row])
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return .init(width: 40, height: 40)
    }

    // MARK: - UI
    private func createCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 20
        layout.minimumInteritemSpacing = 0

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(components.stickerHeaderCell)
        collectionView.showsHorizontalScrollIndicator = false

        return collectionView
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "collectionView")
    }
}
