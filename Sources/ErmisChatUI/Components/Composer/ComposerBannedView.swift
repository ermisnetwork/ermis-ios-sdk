//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

public
class ComposerBannedView: _View, UIProvider {
    private lazy var titleLabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = L10n.ui("ui.you-have-been-banned-from-interacting-in-this-channe")
        label.withoutAutoresizingMaskConstraints
        return label
    }()

    public
    override func setUp() {

    }

    public
    override func setUpUI() {
        self.embed(titleLabel, insets: .init(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    public
    override func setUpTheme() {
        self.backgroundColor = theme.colors.surface
        self.titleLabel.textColor = theme.colors.text
        self.titleLabel.font = theme.fonts.body
    }
}
