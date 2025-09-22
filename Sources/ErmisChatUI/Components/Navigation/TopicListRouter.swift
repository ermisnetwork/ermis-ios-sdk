//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A `NavigationRouter` subclass that handles navigation actions of `TopicListViewController`.
@available(iOSApplicationExtension, unavailable)
open class TopicListRouter: NavigationRouter<TopicListViewController>,
                                ComponentsProvider {
    public
    let modalTransitioningDelegate = ModalTransitioningDelegate()

    /// Shows the view controller with the profile of the current user.
    open func showCurrentUserProfile() {
        log.info(
            """
            Showing current user profile is not handled. Subclass `ChannelListRouter` and provide your \
            implementation of the `\(#function)` method.
            """
        )
    }

    /// Shows the view controller with messages for the provided cid.
    ///
    /// - Parameter cid: The `ChannelId` of the channel the should be presented.
    open func showTopic(for cid: ChannelId, parentCid: ChannelId) {
        showTopic(for: cid, parentCid: parentCid, at: nil)
    }

    /// Shows the view controller with messages for the provided cid and jumps to the given message id.
    /// - Parameters:
    ///   - cid: The `ChannelId` of the channel the should be presented.
    ///   - messageId: The `MessageId` to where the channel should jump to when opening the channel.
    open func showTopic(for cid: ChannelId, parentCid: ChannelId, at messageId: MessageId?) {
        let vc = components.channelVC.init()

        vc.channelController = rootViewController.controller.client.channelController(
            for: cid,
            parentId: parentCid,
            channelListQuery: rootViewController.controller.query
        )

        setDetailViewController(vc, animated: true)
    }

    /// Reset current detailVC if not in collapse mode
    open func unselectedChannel(_ channel: Channel?) {
        
    }

    /// Called when a user tapped `More` swipe action on a channel
    ///
    /// - Parameter cid: `ChannelId` of a channel swipe acton was used on
    open func didTapMoreButton(for cid: ChannelId, parentCid: ChannelId?) {
        log.info(
            """
            Tapping `more` swipe action for channel is not handled. Subclass `ChannelListRouter` and provide your \
            implementation of the `\(#function)` method.
            """
        )
    }

    /// Called when a user tapped `Delete` swipe action on a channel
    ///
    /// - Parameter cid: `ChannelId` of a channel swipe acton was used on
    open func didTapDeleteButton(for cid: ChannelId, parentCid: ChannelId?) {
        log.info(
            """
            Tapping `delete` swipe action for channel is not handled. Subclass `ChannelListRouter` and provide your \
            implementation of the `\(#function)` method.
            """
        )
    }
    // Push a view controller
    open func pushDetailViewController(_ viewController: UIViewController, animated: Bool) {
        viewController.hidesBottomBarWhenPushed = true
        if let splitVC = rootNavigationController?.splitViewController {
            if let nvc = splitVC.viewControllers.last as? UINavigationController {
                nvc.pushViewController(viewController, animated: true)
                return
            }
            let nvc = UINavigationController(rootViewController: viewController)
            splitVC.showDetailViewController(nvc, sender: self)
        } else if let navigationVC = rootViewController.navigationController {
            navigationVC.hidesBottomBarWhenPushed = true
            navigationVC.pushViewController(viewController, animated: true)
        } else {
            let navigationVC = UINavigationController(rootViewController: viewController)
            navigationVC.transitioningDelegate = modalTransitioningDelegate
            navigationVC.modalPresentationStyle = .custom
            navigationVC.hidesBottomBarWhenPushed = true
            rootViewController.show(navigationVC, sender: self)
        }
    }
    // Set details view controller
    open func setDetailViewController(_ viewController: UIViewController, animated: Bool) {
        viewController.hidesBottomBarWhenPushed = true
        if let splitVC = rootNavigationController?.splitViewController {
            let nvc = UINavigationController(rootViewController: viewController)
            nvc.hidesBottomBarWhenPushed = true
            splitVC.showDetailViewController(nvc, sender: self)
        } else if let navigationVC = rootViewController.navigationController {
            navigationVC.hidesBottomBarWhenPushed = true
            navigationVC.pushViewController(viewController, animated: true)
        } else {
            let navigationVC = UINavigationController(rootViewController: viewController)
            navigationVC.transitioningDelegate = modalTransitioningDelegate
            navigationVC.modalPresentationStyle = .custom
            navigationVC.hidesBottomBarWhenPushed = true
            rootViewController.show(navigationVC, sender: self)
        }
    }
    // Present a new view controller.
    open func presentViewController(_ viewController: UIViewController, animated: Bool) {
        viewController.hidesBottomBarWhenPushed = true
        if let splitVC = rootNavigationController?.splitViewController {
            splitVC.present(viewController, animated: animated)
        } else if let navigationVC = rootViewController.navigationController {
            navigationVC.present(viewController, animated: true)
        } else {
            rootViewController.present(viewController, animated: animated)
        }
    }
}
