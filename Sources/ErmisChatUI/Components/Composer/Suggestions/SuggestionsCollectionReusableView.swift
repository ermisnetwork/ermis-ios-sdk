//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The header reusable view of the suggestion collection view.
open class SuggestionsCollectionReusableView: UICollectionReusableView,
    ComponentsProvider {
    /// The reuse identifier of the reusable header view.
    open class var reuseId: String { String(describing: self) }

    /// The suggestions header view.
    open lazy var suggestionsHeader: SuggestionsHeaderView = {
        let header = components.suggestionsHeaderView.init().withoutAutoresizingMaskConstraints
        embed(header)
        return header
    }()
}
