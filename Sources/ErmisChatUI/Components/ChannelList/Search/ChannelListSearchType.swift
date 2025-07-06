//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The channel list search type. It is possible to search by messages or channels.
public struct ChannelListSearchType {
    /// The name of the type.
    public var name: String
    /// The type of search UI component.
    public var searchVC: UIViewController.Type

    public init(searchVC: UIViewController.Type, name: String) {
        self.searchVC = searchVC
        self.name = name
    }

    /// The strategy to search by messages using the default UI component.
    public static let messages: Self = .messages(MessageSearchViewController.self)

    /// The strategy to search by channels using the default UI component.
    public static let channels: Self = .channels(ChannelSearchViewController.self)

    ///
    public static let invitedChannels: Self = .invitedChannels(InvitedChannelSearchViewController.self)

    public static let contactList: Self =  .contactList(ContactSearchViewController.self)

    /// The strategy to search by messages using a custom UI component.
    public static func messages(_ searchVC: MessageSearchViewController.Type) -> Self {
        .init(searchVC: searchVC, name: "messages")
    }

    /// The strategy to search by channels using a custom UI component.
    public static func channels(_ searchVC: ChannelSearchViewController.Type) -> Self {
        .init(searchVC: searchVC, name: "channels")
    }

    public static func invitedChannels(_ searchVC: InvitedChannelSearchViewController.Type) -> Self {
        .init(searchVC: searchVC, name: "invited channels")
    }

    public static func contactList(_ searchVC: ContactListSearchViewController.Type) -> Self {
        .init(searchVC: searchVC, name: "contact list")
    }

    /// Creates the `UISearchController` for the Channel List depending on the current search type.
    public func makeSearchController(
        with channelListVC: ChannelListViewController
    ) -> UISearchController? {
        if let messageSearchVC = searchVC.init() as? MessageSearchViewController {
            let messageSearchController = channelListVC.controller.client.messageSearchController()
            messageSearchVC.messageSearchController = messageSearchController
            messageSearchVC.didSelectMessage = { [weak channelListVC] channel, message in
                channelListVC?.router.showChannel(for: channel.cid, at: message.id)
            }
            let searchController = UISearchController(searchResultsController: messageSearchVC)
            searchController.searchResultsUpdater = messageSearchVC
            return searchController
        }

        if let channelSearchVC = searchVC.init() as? ChannelSearchViewController {
            channelSearchVC.controller = channelListVC.controller
            channelSearchVC.didSelectChannel = { [weak channelListVC] channel in
                channelListVC?.router.showChannel(for: channel.cid)
            }
            let searchController = UISearchController(searchResultsController: channelSearchVC)
            searchController.searchResultsUpdater = channelSearchVC
            return searchController
        }

        if let channelSearchVC = searchVC.init() as? InvitedChannelSearchViewController {
            channelSearchVC.controller = channelListVC.controller
            channelSearchVC.didSelectChannel = { [weak channelListVC] channel in
                channelListVC?.router.showChannel(for: channel.cid)
            }
            let searchController = UISearchController(searchResultsController: channelSearchVC)
            searchController.searchResultsUpdater = channelSearchVC
            return searchController
        }

        if let contactSearchVC = searchVC.init() as? ContactSearchViewController {
            contactSearchVC.controller = channelListVC.controller
            contactSearchVC.didSelectChannel = { [weak channelListVC] channel in
                channelListVC?.router.showChannel(for: channel.cid)
            }
            let searchController = UISearchController(searchResultsController: contactSearchVC)
            searchController.searchResultsUpdater = contactSearchVC
            return searchController
        }
        return nil
    }
}
