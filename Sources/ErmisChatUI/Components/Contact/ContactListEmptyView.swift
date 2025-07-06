//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

open class ContactListEmptyView: ChannelListEmptyView {

    override open func setUp() {
        super.setUp()

        iconView.image = theme.icons.emptyContactList
        titleLabel.text = L10n.ContactList.Empty.title
        subtitleLabel.text = ""
        actionButton.isHidden = true
    }
}
