//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol MessageActionsViewControllerDelegate: AnyObject {
    func messageActionsVC(
        _ vc: MessageActionsViewController,
        message: ChatMessage,
        didTapOnActionItem actionItem: MessageActionItem
    )
    func messageActionsVCDidFinish(_ vc: MessageActionsViewController)
}

/// View controller to show message actions.
open class MessageActionsViewController: _ViewController, UIProvider {
    public weak var delegate: MessageActionsViewControllerDelegate?

    /// `MessageController` instance used to obtain the message data.
    public var messageController: MessageController!

    /// The channel which the actions will be performed.
    public var channel: Channel? {
        didSet {
            channelConfig = channel?.config ?? ChannelConfig()
        }
    }

    /// `ChannelConfig` that contains the feature flags of the channel.
    public var channelConfig: ChannelConfig!

    /// Message that should be shown in this view controller.
    open var message: ChatMessage? {
        messageController.message
    }

    /// The `AlertsRouter` instance responsible for presenting alerts.
    open lazy var alertsRouter = components
        .alertsRouter
        // Temporary solution until the actions router works with with the `UIWindow`
        .init(rootViewController: self.parent ?? self)

    open lazy var presentingAlertRouter = components.alertsRouter.init(rootViewController: self.presentingViewController ?? self)

    /// `ContainerView` for showing message's actions.
    open private(set) lazy var messageActionsContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "messageActionsContainerStackView")

    /// Class used for buttons in `messageActionsContainerView`.
    open var actionButtonClass: MessageActionControl.Type { MessageActionControl.self }

    override open func setUpUI() {
        super.setUpUI()

        view.embed(messageActionsContainerStackView)
        messageActionsContainerStackView.axis = .vertical
        messageActionsContainerStackView.alignment = .fill
        messageActionsContainerStackView.spacing = 1

        // Fix safe area layout issue when message actions go below scroll view
        messageActionsContainerStackView.insetsLayoutMarginsFromSafeArea = false
        messageActionsContainerStackView.isLayoutMarginsRelativeArrangement = true
        messageActionsContainerStackView.layoutMargins = .zero
    }

    override open func setUpTheme() {
        super.setUpTheme()
        messageActionsContainerStackView.layer.cornerRadius = 16
        messageActionsContainerStackView.layer.masksToBounds = true
        messageActionsContainerStackView.backgroundColor = theme.colors.outline
    }

    override open func contentDidChanged() {
        messageActionsContainerStackView.removeAllArrangedSubviews()

        messageActions.forEach {
            let actionView = actionButtonClass.init()
            actionView.containerStackView.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            actionView.content = $0
            messageActionsContainerStackView.addArrangedSubview(actionView)
            actionView.accessibilityIdentifier = "\(type(of: $0))"
        }
    }

    /// Array of `MessageActionItem`s - override this to setup your own custom actions
    open var messageActions: [MessageActionItem] {
        guard
            let currentUser = messageController
                .dataStore
                .currentUser(of: channel?.cid.projectId ?? ""),
            let message = message,
            message.isDeleted == false
        else {
            return []
        }

        switch message.localState {
        case nil:
            var actions: [MessageActionItem] = []

            // If a channel is not set, we fallback to using channelConfig only.
            let canQuoteMessage = channel?.canQuoteMessage ?? channelConfig.quotesEnabled
            let canSendReply = channel?.canSendReply ?? channelConfig.repliesEnabled
            let canUpdateOwnMessage = channel?.canUpdateOwnMessage ?? true
            let canDeleteOwnMessage = (channel?.canDeleteOwnMessage ?? true)
            let canPinMessage = channel?.canPinMessage ?? channelConfig.pinEnabled
            let canForwardMessage = true
            let isSentByCurrentUser = message.isSentByCurrentUser

            if canQuoteMessage {
                actions.append(inlineReplyActionItem())
            }

            if canSendReply && !message.isPartOfThread {
                actions.append(threadReplyActionItem())
            }

            if !isSentByCurrentUser && !message.isPartOfThread {
                actions.append(markUnreadActionItem())
            }

            if !message.text.isEmpty {
                actions.append(copyActionItem())
            }

            if canForwardMessage {
                actions.append(forwardActionItem())
            }

            if canUpdateOwnMessage && message.isSentByCurrentUser && !message.isSticker {
                actions.append(editActionItem())
            }

            if !message.allAttachments.isEmpty {
                actions.append(downloadActionItem())
            }

            if canPinMessage {
                let isPinned = channel?.pinnedMessages.contains(where: { $0.id == message.id}) ?? false
                actions.append(isPinned ? unPinActionItem() : pinActionItem())
            }

            if canDeleteOwnMessage && message.isSentByCurrentUser {
                actions.append(deleteActionItem())
            }

            if canDeleteOwnMessage {
                actions.append(deleteForMeActionItem())
            }

            if let channelConfig = channelConfig,
               channelConfig.mutesEnabled && !message.isSentByCurrentUser {
                let isMuted = currentUser.mutedUsers.map(\.id).contains(message.author.id)
                actions.append(isMuted ? unmuteActionItem() : muteActionItem())
            }

            return actions
        case .sendingFailed:
            return [
                resendActionItem(),
                editActionItem(),
                deleteActionItem()
            ]
        case .pendingSend,
             .pendingSync,
             .syncingFailed,
             .deletingFailed,
             .sending,
             .syncing,
             .deleting:
            return [
                editActionItem(),
                deleteActionItem()
            ]
        }
    }

    /// Returns `MessageActionItem` for edit action
    open func editActionItem() -> MessageActionItem {
        EditActionItem(
            action: { [weak self] in self?.handleAction($0) },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for download action
    open func downloadActionItem() -> MessageActionItem {
        DownloadActionItem(
            action: { [weak self] in self?.handleAction($0) },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for delete action
    open func deleteActionItem() -> MessageActionItem {
        DeleteActionItem(
            action: { [weak self] _ in
                guard let self = self else { return }
                self.alertsRouter.showMessageDeletionConfirmationAlert { confirmed in
                    guard confirmed else { return }

                    self.messageController.deleteMessage(onlyForMe: false) { _ in
                        self.delegate?.messageActionsVCDidFinish(self)
                    }
                }
            },
            theme: theme
        )
    }

    /// Returns `deleteForMeActionItem` for delete action
    open func deleteForMeActionItem() -> MessageActionItem {
        DeleteActionItem(
            title: L10n.Message.Actions.deleteForMe,
            action: { [weak self] _ in
                guard let self = self else { return }
                self.alertsRouter.showMessageDeletionConfirmationAlert { confirmed in
                    guard confirmed else { return }

                    self.messageController.deleteMessage(onlyForMe: true) { _ in
                        self.delegate?.messageActionsVCDidFinish(self)
                    }
                }
            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for resend action.
    open func resendActionItem() -> MessageActionItem {
        ResendActionItem(
            action: { [weak self] _ in
                guard let self = self else { return }
                self.messageController.resendMessage { _ in
                    self.delegate?.messageActionsVCDidFinish(self)
                }
            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for mute action.
    open func muteActionItem() -> MessageActionItem {
        MuteUserActionItem(
            action: { [weak self] _ in
                guard
                    let self = self,
                    let author = self.message?.author
                else { return }

                self.messageController.client
                    .userController(userId: author.id)
                    .mute { _ in self.delegate?.messageActionsVCDidFinish(self) }
            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for unmute action.
    open func unmuteActionItem() -> MessageActionItem {
        UnmuteUserActionItem(
            action: { [weak self] _ in
                guard
                    let self = self,
                    let author = self.message?.author
                else { return }

                self.messageController.client
                    .userController(userId: author.id)
                    .unmute { _ in self.delegate?.messageActionsVCDidFinish(self) }
            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for inline reply action.
    open func inlineReplyActionItem() -> MessageActionItem {
        InlineReplyActionItem(
            action: { [weak self] in self?.handleAction($0) },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for thread reply action.
    open func threadReplyActionItem() -> MessageActionItem {
        ThreadReplyActionItem(
            action: { [weak self] in self?.handleAction($0) },
            theme: theme
        )
    }

    /// Returns `MarkUnreadActionItem` for copy action.
    open func markUnreadActionItem() -> MessageActionItem {
        MarkUnreadActionItem(
            action: { [weak self] in self?.handleAction($0) },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for copy action.
    open func copyActionItem() -> MessageActionItem {
        CopyActionItem(
            action: { [weak self] _ in
                guard let self = self else { return }

                let text: String?
                if let currentUserLang = self.channel?.membership?.language,
                   let translatedText = self.message?.translatedText(for: currentUserLang) {
                    text = translatedText
                } else {
                    text = self.message?.text
                }

                UIPasteboard.general.string = text
                alertsRouter.showInfoAlert(title: L10n.Message.Actions.Copy.successTitle, okHandler: { [weak self] in
                    guard let self else { return }
                    self.delegate?.messageActionsVCDidFinish(self)
                })

            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for forward action.
    open func forwardActionItem() -> MessageActionItem {
        ForwardActionItem(
            action: { [weak self] action in
                guard let self = self else { return }
                handleAction(action)
            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for pin action.
    open func pinActionItem() -> MessageActionItem {
        PinActionItem(
            action: { [weak self] _ in
                guard let self = self else { return }
                self.messageController.pin { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.presentingAlertRouter.showMessagePinResultAlert(false)
                        return
                    }
                    self.presentingAlertRouter.showMessagePinResultAlert(true)
                    self.delegate?.messageActionsVCDidFinish(self)
                }
            },
            theme: theme
        )
    }

    /// Returns `MessageActionItem` for unpin action.
    open func unPinActionItem() -> MessageActionItem {
        UnpinActionItem(
            action: { [weak self] _ in
                guard let self = self else { return }
                self.alertsRouter.showMessageUnpinConfirmationAlert { confirmed in
                    guard confirmed else { return }

                    self.messageController.unpin { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.alertsRouter.showMessageUnpinResultAlert(false)
                            return
                        }
                        self.presentingAlertRouter.showMessageUnpinResultAlert(true)
                        self.delegate?.messageActionsVCDidFinish(self)
                    }
                }
            },
            theme: theme
        )
    }

    /// Triggered for actions which should be handled by `delegate` and not in this view controller.
    open func handleAction(_ actionItem: MessageActionItem) {
        guard let message = message else { return }
        delegate?.messageActionsVC(self, message: message, didTapOnActionItem: actionItem)
    }
}
