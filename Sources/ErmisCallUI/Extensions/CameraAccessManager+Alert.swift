//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat
import ErmisCall

public extension IOAccessManager {
    /// Show camera access required alert.
    func presentCameraAccessAlert(from presentingViewController: UIViewController, animated: Bool) {
        if !isCameraAvailable {
            presentCameraUnavailableAlert(from: presentingViewController, animated: animated)
        } else {
            presentCameraPermissionDeniedAlert(from: presentingViewController, animated: animated)
        }
    }
    /// Show camera access permission is denied alert.
    func presentCameraPermissionDeniedAlert(from presentingViewController: UIViewController,
                                            showSettingAction: Bool = true,
                                            animated: Bool) {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        let appDisplayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? ""

        let alert = UIAlertController(title: L10n.Alert.Title.camera,
                                      message: L10n.Alert.Message.cameraAccessNotgrandted(appDisplayName),
                                      preferredStyle: .alert)

        let cancelActionTitle = L10n.Alert.Actions.ok
        let cancelAction = UIAlertAction(title: cancelActionTitle, style: .cancel)

        let settingsActionTitle = L10n.Alert.Actions.settings
        let settingsAction = UIAlertAction(title: settingsActionTitle, style: .default, handler: { _ in
            UIApplication.shared.open(settingsURL, options: [:], completionHandler: { (succeed) in
                if !succeed {
                    log.debug("[CameraPresenter] Fails to open settings", subsystems: .call)
                }
            })
        })

        alert.addAction(cancelAction)
        if showSettingAction {
            alert.addAction(settingsAction)
        }
        presentingViewController.present(alert, animated: true)
    }
    /// Show camera source unavailable alert.
    func presentCameraUnavailableAlert(from presentingViewController: UIViewController, animated: Bool) {

        let alert = UIAlertController(title: L10n.Alert.Title.camera, message: L10n.Alert.Message.cameraUnavailable, preferredStyle: .alert)

        let okAction = UIAlertAction(title: L10n.Alert.Actions.accept, style: .default, handler: nil)

        alert.addAction(okAction)
        presentingViewController.present(alert, animated: true)
    }
    /// Show microphone permission denied alert.
    func presentMicrophonePermissionDeniedAlert(from presentingViewController: UIViewController,
                                                showSettingAction: Bool = true,
                                                animated: Bool) {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        let appDisplayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? ""

        let alert = UIAlertController(title: L10n.Alert.Title.mic,
                                      message: L10n.Alert.Message.micAccessNotgrandted(appDisplayName),
                                      preferredStyle: .alert)

        let cancelActionTitle = L10n.Alert.Actions.ok
        let cancelAction = UIAlertAction(title: cancelActionTitle, style: .cancel)

        let settingsActionTitle = L10n.Alert.Actions.settings
        let settingsAction = UIAlertAction(title: settingsActionTitle, style: .default, handler: { _ in
            UIApplication.shared.open(settingsURL, options: [:], completionHandler: { (succeed) in
                if !succeed {
                    log.debug("[Microphone] Fails to open settings", subsystems: .call)
                }
            })
        })

        alert.addAction(cancelAction)
        if showSettingAction {
            alert.addAction(settingsAction)
        }
        presentingViewController.present(alert, animated: true)
    }
}

