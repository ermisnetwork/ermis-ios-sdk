//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import ErmisChat

open
class InvitedChannelListViewController: ChannelListViewController, EventsControllerDelegate, InvitedChannelListItemViewDelegate, ChannelConditionRequiredAlertViewDelegate {

    /// The `AlertsRouter` instance responsible for presenting alerts.
    open lazy var alertsRouter = components
        .alertsRouter
    // Temporary solution until the actions router works with with the `UIWindow`
        .init(rootViewController: self.parent ?? self)

    open lazy var _emptyView: ChannelListEmptyView = components
        .invitedChannelListEmptyView.init()
        .withoutAutoresizingMaskConstraints

    open
    override var emptyView: ChannelListEmptyView {
        get {
            return _emptyView
        }
        set {
            _emptyView = newValue
        }
    }

    open
    override var isChannelListStatesEnabled: Bool {
        components.isInvitedChannelListStatesEnabled
    }

    private lazy var eventsController = controller.client.eventsController()

    open
    override func setUp() {
        super.setUp()
        
        collectionView.register(
            components.invitedChannelCell,
            forCellWithReuseIdentifier: components.invitedChannelCell.reuseIdentifier
        )

        collectionView.register(
            components.channelCellSeparator,
            forSupplementaryViewOfKind: ListCollectionViewLayout.separatorKind,
            withReuseIdentifier: separatorReuseIdentifier
        )

        let searchType = components.invitedChannelListSearchType
        let searchController = searchType?.makeSearchController(with: self)
        navigationItem.searchController = searchController
        eventsController.delegate = self
    }

    open
    override func getChannel(at indexPath: IndexPath) -> Channel? {
        let index = indexPath.row
        channels.assertIndexIsPresent(index)
        return channels[safe: index]
    }

    open
    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(with: components.invitedChannelCell, for: indexPath)
        guard let channel = getChannel(at: indexPath) else { return cell }

        cell.itemView.content = .init(
            channel: channel,
            currentUserId: controller.client.currentUserId,
            searchResult: nil
        )

        cell.itemView.delegate = self
        cell.itemView.indexPath = { [weak cell, weak self] in
            guard let cell = cell else { return nil }
            return self?.collectionView.indexPath(for: cell)
        }

        return cell
    }

    open override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard let channel = getChannel(at: indexPath) else { return }
        router.showChannel(for: channel.cid)
    }

    /// Show dialog when user don't have enough conditions to join channel
    open func showChannelConditionRequiredAlert(channel: Channel?,
                                                conditions: [ChannelConditionPayload]) {
        let alert = ChannelConditionRequiredViewController()
        alert.delegate = self
        alert.content = .init(channel: channel,
                              channelConditions: conditions)
        alert.modalPresentationStyle = .overCurrentContext
        present(alert, animated: false)
    }
    // MARK: - EventsControllerDelegate

    open func eventsController(_ controller: EventsController, didReceiveEvent event: Event) {
        // If member is nil mean that channel is not on DB, need to get channel to show invite
        if let memberAddedEvent = event as? MemberAddedEvent,
           memberAddedEvent.memberId == self.controller.client.currentUserId,
           memberAddedEvent.member == nil {
            let cid = memberAddedEvent.cid
            self.controller.loadChannelIfNeeded(cid)
        }
    }
    // MARK: - InvitedChannelListItemViewDelegate
    open func invitedChannelListItemView(_ invitedChannelItem: InvitedChannelListItemView,
                                           didAcceptInviteAt indexPath: IndexPath) {
        guard let channel = channels[safe: indexPath.item] else {
            return
        }
        loadingIndicator.isHidden = false
        controller.acceptInvite(cid: channel.cid) { [weak self] error in
            guard let self = self else {
                return
            }
            DispatchQueue.main.async {
                self.loadingIndicator.isHidden = true
                if let error {
                    if let ermisError = (error as? ClientError)?.ermisApiError,
                       let channelConditions = ermisError.channelConditions {
                        self.showChannelConditionRequiredAlert(channel: channel, conditions: channelConditions)
                        return
                    } else {
                        self.alertsRouter.showInfoAlert(title: "Accept Invitation failed",
                                                        message: error.localizedDescription)
                    }
                } else {
                    guard let channel = self.getChannel(at: indexPath) else {
                        return
                    }
                    self.router.showChannel(for: channel.cid)
                }
            }
        }
    }

    open func invitedChannelListItemView(_ invitedChannelItem: InvitedChannelListItemView,
                                           didRejectInviteAt indexPath: IndexPath) {
        guard let channel = channels[safe: indexPath.item] else {
            return
        }
        loadingIndicator.isHidden = false
        controller.rejectInvite(cid: channel.cid) { [weak self] error in
            guard let self = self else {
                return
            }
            DispatchQueue.main.async {
                self.loadingIndicator.isHidden = true
                if let error {
                    self.alertsRouter.showInfoAlert(title: "Reject Invitation failed",
                                                    message: error.localizedDescription)
                } else {
                    self.router.unselectedChannel(channel)
                }
            }
        }
    }

    open func invitedChannelListItemView(_ invitedChannelItem: InvitedChannelListItemView,
                                           didSkipAt indexPath: IndexPath) {
        guard let channel = channels[safe: indexPath.item] else {
            return
        }
        if channel.membership?.memberRole == .pending {
            loadingIndicator.isHidden = false
            controller.skipInvite(cid: channel.cid) { [weak self] error in
                guard let self = self else {
                    return
                }
                DispatchQueue.main.async {
                    self.loadingIndicator.isHidden = true
                    if let error {
                        self.alertsRouter.showInfoAlert(title: "Skip Invitation failed",
                                                        message: error.localizedDescription)
                    } else {
                        self.router.unselectedChannel(channel)
                    }
                }
            }
        } else {
            self.router.unselectedChannel(channel)
        }
    }
    // MARK: - ChannelConditionRequiredAlertViewDelegate
    open func channelConditionRequiredAlertDidClose(_ alert: ChannelConditionRequiredView) {
        dismiss(animated: true)
    }

    open func channelConditionRequiredAlertDidReCheck(_ alert: ChannelConditionRequiredView) {
        guard let channel = alert.content?.channel else {
            return
        }
        controller.acceptInvite(cid: channel.cid) { [weak self] error in
            guard let self = self else {
                return
            }
            DispatchQueue.main.async {
                self.loadingIndicator.isHidden = true
                if let error {
                    self.alertsRouter.showInfoAlert(title: "Accept Invitation failed",
                                                    message: error.localizedDescription)
                } else {
                    self.dismiss(animated: false, completion: {
                        self.router.showChannel(for: channel.cid)
                    })
                }
            }
        }
    }

    open func channelConditionRequiredAlert(_ alert: ChannelConditionRequiredView,
                                              didSelectGetTokensFor condition: ErmisChat.ChannelConditionPayload) {
        guard let url = URL(string: condition.linkToPurchase) else {
            return
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
