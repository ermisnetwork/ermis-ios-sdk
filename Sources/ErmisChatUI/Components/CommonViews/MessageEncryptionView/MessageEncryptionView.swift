//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisSharedUI

open class MessageEncryptionView: _View, UIProvider {
    private lazy var encryptionImageView = UIImageView()


    open override func setUp() {
        super.setUp()
        encryptionImageView.image = theme.icons.encryption
    }

    open override func setUpUI() {
        super.setUpUI()
        embed(encryptionImageView)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        encryptionImageView.tintColor = theme.colors.primary
    }
}
