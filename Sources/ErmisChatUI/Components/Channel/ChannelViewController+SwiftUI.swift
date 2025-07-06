//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import SwiftUI

@available(iOSApplicationExtension, unavailable)
extension ChannelViewController: SwiftUIRepresentable {
    public var content: ChannelController {
        get {
            channelController
        }
        set {
            channelController = newValue
        }
    }
}
