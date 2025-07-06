//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The object that acts as the delegate of the message list.
public protocol MessageListViewControllerDelegate: AnyObject {
    /// Tells the delegate the message list is about to draw a message for a particular row.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - indexPath: An index path locating the row in the message list.
    func messageListVC(
        _ vc: MessageListViewController,
        willDisplayMessageAt indexPath: IndexPath
    )

    /// Tells the delegate when the user scrolls the content view within the receiver.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - scrollView: The scroll view that belongs to the message list.
    func messageListVC(
        _ vc: MessageListViewController,
        scrollViewDidScroll scrollView: UIScrollView
    )

    /// Tells the delegate when the user taps on an action for the given message.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - actionItem: The action performed on the given message.
    ///   - message: The given message.
    func messageListVC(
        _ vc: MessageListViewController,
        didTapOnAction actionItem: MessageActionItem,
        for message: ChatMessage
    )

    /// Tells the delegate when the user taps on the message list view.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - messageListView: The message list view.
    ///   - gestureRecognizer: The tap gesture recognizer that triggered the event.
    func messageListVC(
        _ vc: MessageListViewController,
        didTapOnMessageListView messageListView: MessageListView,
        with gestureRecognizer: UITapGestureRecognizer
    )

    /// Asks the delegate if jump to unread should be shown.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    func messageListShouldShowJumpToUnread(_ vc: MessageListViewController) -> Bool

    /// Tells the delegate when the user discards jumping to unread messages.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    func messageListDidDiscardUnreadMessages(_ vc: MessageListViewController)

    /// Tells the delegate that it should load the page around the given message id.
    ///
    /// Ex: The user tapped on a quoted message which is not locally available.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - messageId: The id of the message  to load the page around it.
    ///   - onSuccess: Call this closure when the page is successfully loaded.
    func messageListVC(
        _ vc: MessageListViewController,
        shouldLoadPageAroundMessageId messageId: MessageId,
        _ completion: @escaping ((Error?) -> Void)
    )

    /// Tells the delegate that it should load the first page.
    ///
    /// Ex: The user tapped on scroll to the bottom or sent a new message when the first page is not currently in the UI.
    /// - Parameter vc: The message list informing the delegate of this event.
    func messageListVCShouldLoadFirstPage(
        _ vc: MessageListViewController
    )
    
    /// Ask the delegate to provide a header view for the specified decoration type.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - message: The given message.
    ///   - indexPath: An index path locating the row in the message list.
    func messageListVC(
        _ vc: MessageListViewController,
        headerViewForMessage message: ChatMessage,
        at indexPath: IndexPath
    ) -> MessageCellHeaderFooterView?

    /// Ask the delegate to provide a footer view for the specified decoration type.
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - message: The given message.
    ///   - indexPath: An index path locating the row in the message list.
    func messageListVC(
        _ vc: MessageListViewController,
        footerViewForMessage message: ChatMessage,
        at indexPath: IndexPath
    ) -> MessageCellHeaderFooterView?
}

public extension MessageListViewControllerDelegate {
    /// A helper method to create the DateSeparator that is used
    /// - Parameters:
    ///   - vc: The message list informing the delegate of this event.
    ///   - message: The given message.
    ///   - indexPath: An index path locating the row in the message list.
    ///   - components: The components to use in order to access the DateSeparatorView type
    func dateHeaderView(
        _ vc: MessageListViewController,
        headerViewForMessage message: ChatMessage,
        at indexPath: IndexPath,
        components: Components = .default
    ) -> MessageCellHeaderFooterView? {
        guard vc.shouldShowDateSeparator(forMessage: message, at: indexPath) else {
            return nil
        }
        let dateSeparatorView = components.messageListDateSeparatorView.init()
        dateSeparatorView.content = vc.dateSeparatorFormatter.format(message.createdAt)
        return dateSeparatorView
    }

    // MARK: - Default Implementations

    func messageListShouldShowJumpToUnread(_ vc: MessageListViewController) -> Bool { false }

    func messageListDidDiscardUnreadMessages(_ vc: MessageListViewController) {}

    func messageListVC(
        _ vc: MessageListViewController,
        shouldLoadPageAroundMessageId messageId: MessageId,
        _ completion: @escaping ((Error?) -> Void)
    ) {
        completion(nil)
    }

    func messageListVCShouldLoadFirstPage(_ vc: MessageListViewController) {
        // no-op
    }
 
    func messageListVC(
        _ vc: MessageListViewController,
        headerViewForMessage message: ChatMessage,
        at indexPath: IndexPath
    ) -> MessageCellHeaderFooterView? {
        dateHeaderView(vc, headerViewForMessage: message, at: indexPath)
    }

    func messageListVC(
        _ vc: MessageListViewController,
        footerViewForMessage message: ChatMessage,
        at indexPath: IndexPath
    ) -> MessageCellHeaderFooterView? {
        nil
    }
}
