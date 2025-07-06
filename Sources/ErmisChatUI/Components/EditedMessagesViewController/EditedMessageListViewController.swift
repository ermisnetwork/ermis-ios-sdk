//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

open class EditedMessageListViewController: _ViewController, UIProvider, UITableViewDataSource, UITableViewDelegate {
    public private(set) lazy var tableView = createTableView()

    public var messageController: MessageController? {
        didSet {
            updateContentIfNeeded()
        }
    }

    private var editedMessagesHitory: [MessageEditHistory] {
        return messageController?.message?.oldTexts?.sorted(by: { $0.createdAt > $1.createdAt}) ?? []
    }

    // MARK: - Setup
    open override func setUp() {
        tableView.reloadData()
        self.title = "Edited Messages History"
    }

    open override func setUpUI() {
        super.setUpUI()
        view.addSubview(tableView)
        view.embed(tableView)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        view.backgroundColor = theme.colors.surface
        tableView.backgroundColor = theme.colors.surface
    }

    open override func contentDidChanged() {
        tableView.reloadData()
    }

    // MARK: - Create UI
    private func createTableView() -> UITableView {
        let tableView = UITableView()
        tableView.register(EditedMessageCell.self)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        return tableView.withoutAutoresizingMaskConstraints
    }

    // MARK: - UITableViewDelegate + DataSource
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messageController?.message?.oldTexts?.count ?? 0
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: EditedMessageCell = tableView.dequeueReusableCell(with: EditedMessageCell.self, for: indexPath)
        cell.content = editedMessagesHitory[indexPath.row]
        return cell
    }
}
