//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import SwiftUI

@available(iOSApplicationExtension, unavailable)
extension ThreadViewController: SwiftUIRepresentable {
    public var content: (
        channelController: ChannelController,
        messageController: MessageController
    ) {
        get {
            (channelController, messageController)
        }
        set {
            channelController = newValue.channelController
            messageController = newValue.messageController
        }
    }
}
