//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

/// A component used to present the user with a tip on how to initiate the
/// recording flow.
open class RecordingTipView: _View, UIProvider {
    // MARK: - UI Components

    /// The main container where all components will be added into.
    open lazy var container: UIView = .init()
        .withoutAutoresizingMaskConstraints

    /// The label that shows the prompt message to the user.
    open lazy var titleLabel: UILabel = .init()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport

    // MARK: - Lifecycle

    override open func setUpUI() {
        super.setUpUI()

        embed(container)
        container.embed(titleLabel, insets: .init(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    override open func setUpTheme() {
        super.setUpTheme()

        backgroundColor = nil
        container.backgroundColor = theme.colors.outline
        titleLabel.font = theme.fonts.caption1.bold
        titleLabel.textColor = theme.colors.text
        titleLabel.textAlignment = .center
        titleLabel.text = L10n.Recording.tip
    }
}
