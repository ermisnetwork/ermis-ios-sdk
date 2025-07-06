//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

/// The object that acts as the data source of the message list.
public protocol MessageListViewControllerDataSource: AnyObject {
    /// Asks the data source if the first (newest) page is currently loaded.
    var isFirstPageLoaded: Bool { get }
    
    /// Asks the data source if the last (oldest) page is currently loaded.
    var isLastPageLoaded: Bool { get }

    /// Asks the data source to return all the available messages.
    var messages: [ChatMessage] { get set }

    /// Asks the data source to return the channel for the given message list.
    /// - Parameter vc: The message list requesting the channel.
    func channel(for vc: MessageListViewController) -> Channel?

    /// Asks the data source to return the number of messages in the message list.
    /// - Parameter vc: The message list requesting the number of messages.
    func numberOfMessages(in vc: MessageListViewController) -> Int

    /// Asks the data source for the message in a particular location of the message list.
    /// - Parameters:
    ///   - vc: The message list requesting the message.
    ///   - indexPath: An index path locating the row in the message list.
    func messageListVC(
        _ vc: MessageListViewController,
        messageAt indexPath: IndexPath
    ) -> ChatMessage?

    /// Asks the data source for the message layout options in a particular location of the message list.
    /// - Parameters:
    ///   - vc: The message list requesting the layout options.
    ///   - indexPath: An index path locating the row in the message list.
    func messageListVC(
        _ vc: MessageListViewController,
        messageLayoutOptionsAt indexPath: IndexPath
    ) -> MessageLayoutOptions
}

/// Default implementations to avoid breaking changes.
/// Ideally should be implemented by customers who use the `MessageListViewController` directly (Advanced).
public extension MessageListViewControllerDataSource {
    var isFirstPageLoaded: Bool {
        true
    }

    var isLastPageLoaded: Bool {
        false
    }
}
