//
// Copyright 2025 Ermis Inc.
//

import UIKit

open class InvitedChannelListEmptyView: ChannelListEmptyView {

    override open func setUp() {
        super.setUp()

        titleLabel.text = L10n.InvitedChannelList.Empty.title
        subtitleLabel.text = ""
        actionButton.isHidden = true
    }
}
