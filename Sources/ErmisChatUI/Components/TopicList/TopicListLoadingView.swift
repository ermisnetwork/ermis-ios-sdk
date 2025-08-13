 //
// Copyright 2025 Ermis Inc.
//

import UIKit

/// Default implementation for the loading state view, using a similar layout of the Channel list animating each UI element in the cells with a shimmer.
open class TopicListLoadingView: _View, UIProvider, UITableViewDataSource {
    open private(set) lazy var tableView = UITableView()
        .withoutAutoresizingMaskConstraints

    /// Int value that determines the number of cells that are layout when the `ChannelListLoadingView` is shown.
    open var numberOfCells = 15

    open override var isHidden: Bool {
        didSet {
            if !isHidden {
                updateContentIfNeeded()
            }
        }
    }

    override open func setUp() {
        super.setUp()

        isUserInteractionEnabled = false

        tableView.dataSource = self
        tableView.isScrollEnabled = false
        tableView.register(components.channelListLoadingViewCell)
    }

    override open func setUpUI() {
        super.setUpUI()

        addSubview(tableView)
        tableView.pin(anchors: [.leading, .trailing, .bottom], to: self)
        tableView.pin(anchors: [.top], to: safeAreaLayoutGuide)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        tableView.visibleCells.forEach { $0.layoutSubviews() }
    }

    open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        numberOfCells
    }

    open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(with: components.channelListLoadingViewCell, for: indexPath)
    }
}
