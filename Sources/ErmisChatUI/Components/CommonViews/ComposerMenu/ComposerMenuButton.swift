//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public enum ComposerMenuItemType: Equatable {
    case location
    case file
    case poll
    case custom(String)

    public var rawValue: String {
        switch self {
        case .location:
            return "location"
        case .file:
            return "file"
        case .poll:
            return "poll"
        case .custom(let rawValue):
            return rawValue
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.rawValue == rhs.rawValue
    }
}

/// Button for showing menu actions.
open class ComposerMenuButton: _Button, ThemeProvider {

    public private(set) var items: [ComposerMenuItemType] = [.poll, .file]
    public var onMenuItemDidTapped: ((ComposerMenuItemType) -> Void)?

    public required init() {
        super.init(frame: .zero)
    }

    public required init(items: [ComposerMenuItemType]) {
        self.items = items
        super.init(frame: .zero)
    }

    @MainActor public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override func setUp() {
        super.setUp()
        menu = createMenu()
        showsMenuAsPrimaryAction = true
    }

    open override func setUpUI() {
        super.setUpUI()
        layer.cornerRadius = 19
    }

    override open func setUpTheme() {
        super.setUpTheme()

        let menuIcon = theme.icons.add
        let closeIcon = theme.icons.close
        setImage(menuIcon, for: .normal)
        setImage(closeIcon, for: .highlighted)
        backgroundColor = theme.colors.primary
        tintColor = theme.colors.onPrimary
    }

    open func createMenu() -> UIMenu {
        let menu = UIMenu(children: menuItems())
        return menu
    }

    open func menuItems() -> [UIMenuElement] {
        return items.map { item in
            UIAction(title: title(for: item), image: icon(for: item)) { [weak self] _ in
                self?.onMenuItemDidTapped?(item)
            }
        }
    }

    open func title(for item: ComposerMenuItemType) -> String {
        switch item {
            case .location:
            return L10n.Composer.Menu.location
        case .file:
            return L10n.Composer.Menu.shareFile
        case .poll:
            return L10n.Composer.Menu.createPoll
        case .custom(let rawValue):
            return rawValue.capitalized
        }
    }

    open func icon(for item: ComposerMenuItemType) -> UIImage? {
        switch item {
            case .location:
            return theme.icons.composerMenuLocation
        case .file:
            return theme.icons.composerMenuFile
        case .poll:
            return theme.icons.composerMenuPoll
        case .custom(let rawValue):
            return nil
        }
    }
}
