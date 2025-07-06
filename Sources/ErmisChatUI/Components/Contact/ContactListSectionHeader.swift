//
// Copyright 2025 Ermis Inc.
//

import UIKit

open
class ContactListSectionHeader: _CollectionReusableView, ThemeProvider {
    private lazy var titleLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "titleLabel")

    public var content: ContactListSection? {
        didSet {
            updateContentIfNeeded()
        }
    }

    open
    override func setUp() {
        super.setUp()
    }

    open
    override func setUpUI() {
        super.setUpUI()
        self.embed(titleLabel, insets: .init(top: 8, leading: 24, bottom: 8, trailing: 24))
    }

    open
    override func setUpTheme() {
        super.setUpTheme()
        titleLabel.textColor = theme.colors.subtitleText
        titleLabel.font = theme.fonts.title3
    }

    open
    override func contentDidChanged() {
        titleLabel.text = content?.title
    }
}

