//
// Copyright 2025 Ermis Inc.
//

import Combine
import Foundation

extension CurrentUserController {
    /// A publisher emitting a new value every time the current user changes.
    public var currentUserChangePublisher: AnyPublisher<EntityChange<CurrentChatUser>, Never> {
        basePublishers.currentUserChange.keepAlive(self)
    }

    /// A publisher emitting a new value every time the unread count changes..
    public var unreadCountPublisher: AnyPublisher<UnreadCount, Never> {
        basePublishers.unreadCount.keepAlive(self)
    }

    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    class BasePublishers {
        /// The wrapper controller
        unowned let controller: CurrentUserController

        /// A backing subject for `currentUserChangePublisher`.
        let currentUserChange: PassthroughSubject<EntityChange<CurrentChatUser>, Never> = .init()

        /// A backing subject for `unreadCountPublisher`.
        let unreadCount: CurrentValueSubject<UnreadCount, Never>

        init(controller: CurrentUserController) {
            self.controller = controller
            unreadCount = .init(controller.unreadCount)

            controller.multicastDelegate.add(additionalDelegate: self)
        }
    }
}

extension CurrentUserController.BasePublishers: CurrentUserControllerDelegate {
    func currentUserController(
        _ controller: CurrentUserController,
        didChangeCurrentUserUnreadCount unreadCount: UnreadCount
    ) {
        self.unreadCount.send(unreadCount)
    }

    func currentUserController(
        _ controller: CurrentUserController,
        didChangeCurrentUser currentUser: EntityChange<CurrentChatUser>
    ) {
        currentUserChange.send(currentUser)
    }
}
