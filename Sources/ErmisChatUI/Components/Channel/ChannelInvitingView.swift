//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

open
class ChannelInvitingView: _View, UIProvider {
    var directUserName: String? {
        didSet {
            contentDidChanged()
        }
    }

    open private(set) lazy var titleLabel: UILabel = {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
            .withAdjustingFontForContentSizeCategory
            .withBidirectionalLanguagesSupport
            .withAccessibilityIdentifier(identifier: "titleLabel")
            .multiline

    }()

    open override func setUp() {
        clipsToBounds = true
    }

    open 
    override func setUpUI() {
        self.embed(titleLabel, insets: .init(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    open
    override func contentDidChanged() {
        guard let directUserName else {
            return
        }
        titleLabel.text = L10n.Channel.Invitation.pendingUserNeedAccept(directUserName)
    }

    open
    override func setUpTheme() {
        backgroundColor = theme.colors.surfaceContainer
        titleLabel.textColor = theme.colors.text
        titleLabel.font = theme.fonts.body
    }

    var ideaHeight: CGFloat {
        return titleLabel.calculateHeight + 10
    }
}
