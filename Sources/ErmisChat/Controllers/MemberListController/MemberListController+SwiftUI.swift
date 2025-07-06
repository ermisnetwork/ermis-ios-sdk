//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import SwiftUI

extension ChannelMemberListController {
    /// A wrapper object that exposes the controller variables in the form of `ObservableObject` to be used in SwiftUI.
    public var observableObject: ObservableObject { .init(controller: self) }

    /// A wrapper object for `ChannelMemberListController` type which makes it possible to use the controller
    /// comfortably in SwiftUI.
    public class ObservableObject: SwiftUI.ObservableObject {
        /// The underlying controller. You can still access it and call methods on it.
        public let controller: ChannelMemberListController

        /// The channel members.
        @Published public private(set) var members: LazyCachedMapCollection<ChannelMember> = []

        /// The current state of the controller.
        @Published public private(set) var state: DataController.State

        /// Creates a new `ObservableObject` wrapper with the provided controller instance.
        init(controller: ChannelMemberListController) {
            self.controller = controller
            state = controller.state

            controller.multicastDelegate.add(additionalDelegate: self)

            members = controller.members
        }
    }
}

extension ChannelMemberListController.ObservableObject: ChannelMemberListControllerDelegate {
    public func memberListController(
        _ controller: ChannelMemberListController,
        didChangeMembers changes: [ListChange<ChannelMember>]
    ) {
        members = controller.members
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
    }
}
