//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A `NavigationRouter` instance responsible for presenting alerts.
open class AlertsRouter: NavigationRouter<UIViewController> {
    /// Shows an alert with confirmation for message deletion.
    ///
    /// - Parameters:
    ///     - confirmed: Completion closure with a `Bool` parameter indicating whether the deletion has been confirmed or not.
    ///
    open func showMessageDeletionConfirmationAlert(confirmed: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: L10n.Message.Actions.Delete.confirmationTitle,
            message: L10n.Message.Actions.Delete.confirmationMessage,
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(
                title: L10n.Alert.Actions.cancel,
                style: .cancel,
                handler: { _ in confirmed(false) }
            )
        )
        alert.addAction(
            UIAlertAction(
                title: L10n.Alert.Actions.delete,
                style: .destructive,
                handler: { _ in confirmed(true) }
            )
        )

        rootViewController.present(alert, animated: true)
    }

    /// Shows an alert with confirmation for message flag.
    ///
    /// - Parameters:
    ///     - confirmed: Completion closure with a `Bool` parameter indicating whether the deletion has been confirmed or not.
    ///
    open func showMessageFlagConfirmationAlert(confirmed: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: L10n.Message.Actions.Flag.confirmationTitle,
            message: L10n.Message.Actions.Flag.confirmationMessage,
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(
                title: L10n.Alert.Actions.cancel,
                style: .cancel,
                handler: { _ in confirmed(false) }
            )
        )
        alert.addAction(
            UIAlertAction(
                title: L10n.Alert.Actions.flag,
                style: .destructive,
                handler: { _ in confirmed(true) }
            )
        )

        rootViewController.present(alert, animated: true)
    }

    // MARK: - Show pin

    /// Shows an alert with confirmation for message unpin.
    ///
    /// - Parameters:
    ///     - confirmed: Completion closure with a `Bool` parameter indicating whether the unpin has been confirmed or not.
    ///
    open func showMessageUnpinConfirmationAlert(confirmed: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: L10n.Message.Actions.Unpin.confirmationTitle,
            message: L10n.Message.Actions.Unpin.confirmationMessage,
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(
                title: L10n.Alert.Actions.cancel,
                style: .cancel,
                handler: { _ in confirmed(false) }
            )
        )
        alert.addAction(
            UIAlertAction(
                title: L10n.Alert.Actions.unpin,
                style: .destructive,
                handler: { _ in confirmed(true) }
            )
        )

        rootViewController.present(alert, animated: true)
    }

    /// Shows an toast that notify to user that message has been pinned success or not.
    ///
    /// - Parameters:
    ///     - isSuccess: A `Bool` parameter indicating whether the pinned message operation is success or not.
    ///
    open func showMessagePinResultAlert(_ isSuccess: Bool) {
        showToast(title: isSuccess ? L10n.Message.Actions.Pin.successMessage : L10n.Message.Actions.Pin.unsuccessMessage,
                  message: nil,
                  style: .success)
    }

    /// Shows an toast that notify to user that message has been unpinned success or not.
    ///
    /// - Parameters:
    ///     - isSuccess: A `Bool` parameter indicating whether the unpinned message operation is success or not.
    ///
    open func showMessageUnpinResultAlert(_ isSuccess: Bool) {
        showToast(title: isSuccess ? L10n.Message.Actions.Unpin.successMessage : L10n.Message.Actions.Unpin.unsuccessMessage,
                  message: nil,
                  style: isSuccess ? .success : .error)
    }

    // MARK: - Forwarding message
    open func showMessageForwardingAlert(_ isSuccess: Bool) {
        showToast(
            title: isSuccess ? L10n.Message.Actions.Forward.successTitle : L10n.Message.Actions.Forward.failureTitle,
            style: isSuccess ? .success : .error
        )
    }

    // MARK: - Input validate alerts

    /// Shows an toast that notify to user that input text contain filter word.
    open func showInputTextContaintFilterWordAlert() {
        ToastManager.removeAllToast()
        showToast(title: L10n.Composer.Filterwords.contentContainBlockedKeywords,
                  duration: 2)
    }

    /// Shows an toast that notify to user that input text contain link.
    open func showCanNotSendLinkAlert() {
        ToastManager.removeAllToast()
        showToast(title: L10n.Composer.LinksDisabled.subtitle,
                  message: nil,
                  duration: 2)

    }

    open func showDownloadAttachmentAlertResult(isSuccess: Bool) {
        showToast(title: isSuccess ? L10n.Message.Actions.Download.successTitle:
                    L10n.Message.Actions.Download.failureTitle,
                  style: isSuccess ? .success : .error)
    }

    open func showInfoAlert(title: String? = nil,
                            message: String? = nil,
                            preferredStyle: UIAlertController.Style = .alert,
                            sourceView: UIView? = nil,
                            okHandler: (() -> Void)? = nil) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: preferredStyle
        )

        alert.popoverPresentationController?.sourceView = sourceView ?? self.rootViewController.view

        alert.addAction(.init(title: "Ok", style: .default, handler: {_ in
            okHandler?()
        }))

        rootViewController.present(alert, animated: true)
    }

    open func showToast(title: String? = nil,
                           message: String? = nil,
                           style: ToastStyle = .error,
                           position: ToastPosition = .bottom,
                           duration: TimeInterval = 4) {
        DispatchQueue.main.async(execute: {
            ToastManager.showToast(title: title,
                                   message: message,
                                   style: style,
                                   duration: duration,
                                   position: position,
                                   in: self.rootViewController.view)
        })

    }
}
