//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import SwiftUI

// A `UIViewControllerRepresentable` subclass which wraps `ChannelListViewController` and shows list of channels.
public typealias ChannelList = SwiftUIViewControllerRepresentable<ChannelListViewController>

@available(iOSApplicationExtension, unavailable)
extension ChannelListViewController: SwiftUIRepresentable {
    public var content: ChannelListController {
        get {
            controller
        }
        set {
            controller = newValue
        }
    }
}
