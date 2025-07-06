//
// Copyright 2025 Ermis Inc.
//

import Foundation
import Combine
import SwiftUI

extension ChannelMemberController {
    /// A wrapper object that exposes the controller variables in the form of `ObservableObject` to be used in SwiftUI.
    public var observableObject: ObservableObject { .init(controller: self) }

    /// A wrapper object for `ChannelMemberController` type which makes it possible to use the controller
    /// comfortably in SwiftUI.
    public class ObservableObject: SwiftUI.ObservableObject {
        /// The underlying controller. You can still access it and call methods on it.
        public let controller: ChannelMemberController

        /// The channel member.
        @Published public private(set) var member: ChannelMember?

        /// The current state of the controller.
        @Published public private(set) var state: DataController.State

        /// Creates a new `ObservableObject` wrapper with the provided controller instance.
        init(controller: ChannelMemberController) {
            self.controller = controller
            state = controller.state

            controller.multicastDelegate.add(additionalDelegate: self)

            member = controller.member
        }
    }
}

extension ChannelMemberController.ObservableObject: ChannelMemberControllerDelegate {
    public func memberController(
        _ controller: ChannelMemberController,
        didUpdateMember change: EntityChange<ChannelMember>
    ) {
        member = change.item
    }

    public func controller(_ controller: DataController, didChangeState state: DataController.State) {
        self.state = state
    }
}
