//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view cell that displays a command.
open class CommandSuggestionCollectionViewCell: _CollectionViewCell, ComponentsProvider {
    open class var reuseId: String { String(describing: self) }

    public private(set) lazy var commandView = components
        .suggestionsCommandView.init()
        .withoutAutoresizingMaskConstraints

    override open func setUpUI() {
        super.setUpUI()

        contentView.embed(commandView)
    }
}
