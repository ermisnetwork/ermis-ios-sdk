//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import ErmisCall
import UIKit
import AVKit
import Combine

public protocol PiPRouterDelegate: AnyObject {
    func pipRouter(_ router: PiPRouter, wantsToShow callVC: UIViewController, completion: (() -> Void)?)
    func callViewController(_ router: PiPRouter, for callController: CallController) -> UIViewController
//    func pipRouter(_ router: PiPRouter, wantsToDismiss callVC: UIViewController, completion: (() -> Void)?)
//    func pipRouter(_ router: PiPRouter, wantsToMinimize callVC: UIViewController, completion: (() -> Void)?)
//    func pipRouter(_ router: PiPRouter, wantsToExpand callVC: UIViewController, completion: (() -> Void)?)
}
/// A class for enter/exit PiP mode.
@MainActor
public class PiPRouter: NSObject {
    public var pipController: AVPictureInPictureController?
    public var callController: CallController?
    public weak var renderView: VideoRenderView?
    public var pipContentViewController: PiPVideoCallViewController?
    public weak var delegate: PiPRouterDelegate?
    public var presentedCallVC: UIViewController?

    public var callDetails: CallDetails?

    private var cancellables = Set<AnyCancellable>()

    public var isInPip: Bool = false

    public var errorMessage: CallManagerMessage?

    @MainActor
    public func setup(with callController: CallController, callDetails: CallDetails) {
        guard let call  = callController.call else {
            log.warning("[PipRouter] Failed to setup PiP: callController isNil: \(callController == nil), delegate isNil: \(delegate == nil)", subsystems: .call)
            return
        }
        
//        cleanup()
        addCallMessageObserver()
        self.callDetails = callDetails
        renderView = call.renderView
        self.callController = callController

        pipContentViewController = PiPVideoCallViewController()
        let ratio: CGFloat = 12.0 / 9.0
        let deviceRatio = UIScreen.main.bounds.height / UIScreen.main.bounds.width
        // Change frame ratio to pip ratio for scale animation.
        var newFrame: CGRect
        if deviceRatio < ratio {
            newFrame = .init(origin: .zero, size: CGSize(width: UIScreen.main.bounds.height / ratio,
                                                         height: UIScreen.main.bounds.height))
        } else {
            newFrame = .init(origin: .zero, size: CGSize(width: UIScreen.main.bounds.width,
                                                         height: UIScreen.main.bounds.width * ratio))
        }


        pipContentViewController?.preferredContentSize = CGSize(width: newFrame.width, height: newFrame.height)
        let pipContentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: call.renderView,
            contentViewController: pipContentViewController!
        )

        pipController = AVPictureInPictureController(contentSource: pipContentSource)
        pipController?.delegate = self
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    /// Show new call screen
    ///
    /// - Parameters:
    ///  - callVC: The new call viewcontroller instance need to show.
    ///  - completion: The completion handler closure when finish.
    @MainActor
    public func showCallVC(_ callController: CallController, callDetails: CallDetails, completion: (() -> Void)? = nil) {
        if isInPip {
            stopPip(completion: completion)
            log.warning("[PipRouter] is inpip, stop pip to show call.", subsystems: .call)
            return
        }
        setup(with: callController, callDetails: callDetails)
        guard let delegate else {
            fatalError("[PipRouter] Delegate is not set")
        }
        let vc = delegate.callViewController(self, for: callController)
        guard let vc = vc as? UINavigationController,
              let callVC = vc.viewControllers.first as? CallViewController else {
            completion?()
            log.warning("[PipRouter] call vc is not UINavigationController or not CallViewController", subsystems: .call)
            return
        }

        if let renderView = callController.call?.renderView {
            callVC.remoteVideoView.attach(with: renderView)
            
        }
        self.presentedCallVC = vc
        delegate.pipRouter(self, wantsToShow: vc, completion: { [weak self] in
            completion?()
        })
    }

    /// Hide call view controller.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to remove.
    ///  - completion: The completion handler closure when finish.

    @MainActor
    public func dismissCallVC(_ callVC: CallViewController, completion: (() -> Void)? = nil) {
        log.debug("[PipRouter] dismissCallVC called, presentedCallVC: \(String(describing: presentedCallVC))", subsystems: .call)
        guard callVC.presentedViewController == nil else {
            callVC.dismiss(animated: false) {
                self.dismissCallVC(callVC, completion: completion)
            }
            return
        }
        // Get the navigation controller that contains the call VC
        guard let navController = callVC.navigationController ?? presentedCallVC else {
            log.warning("[PipRouter] No navigation controller to dismiss", subsystems: .call)
            self.cleanup()
            completion?()
            return
        }

        guard !navController.isBeingDismissed else {
            log.debug("[PipRouter] Navigation controller already being dismissed, skipping", subsystems: .call)
            self.cleanup()
            completion?()
            return
        }

        log.debug("[PipRouter] Dismissing navigation controller", subsystems: .call)
//        navController.dismiss(animated: true, completion: { [weak self] in
//            log.debug("[PipRouter] Dismiss completed")
//            completion?()
//        })
        self.cleanup()
        completion?()

    }

    /// Enter PiP mode.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to enter PiP.
    ///  - completion: The completion handler closure when finish.
    @MainActor public func startPip(completion: (() -> Void)? = nil) {
        guard !isInPip else {
            log.warning("[PipRouter] Start pip failed - already in pip", subsystems: .call)
            return
        }
        isInPip = true
        guard let pipController else {
            return
        }
        pipController.startPictureInPicture()
    }

    /// Exit PiP mode.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to exit PiP mode
    ///  - completion: The completion handler closure when finish.
    @MainActor
    public func stopPip(completion: (() -> Void)? = nil) {
        guard isInPip else {
            log.warning("[PipRouter] Stop pip failed - already exit pip")
            return
        }
        guard let pipController else {
            return
        }
        isInPip = false
        defer {
            log.debug("[PipRouter] Begin stop pip", subsystems: .call)
            pipController.stopPictureInPicture()
        }
//        guard isInPip else {
//            log.warning("[PipRouter] Stop pip failed - already exit pip")
//            return
//        }
    }

    public func callDidEnded(_ callUuid: String) {
        log.debug("[PipRouter] Call did ended: \(callUuid), isInPip: \(isInPip)", subsystems: .call)

        log.debug("[PipRouter] callDidEnded - received uuid: \(callUuid)", subsystems: .call)
        log.debug("[PipRouter] callDidEnded - callDetails: \(String(describing: callDetails))", subsystems: .call)
        log.debug("[PipRouter] callDidEnded - callDetails.uuid: \(String(describing: callDetails?.uuid.uuidString))", subsystems: .call)
        log.debug("[PipRouter] callDidEnded - presentedCallVC: \(String(describing: presentedCallVC))", subsystems: .call)
        log.debug("[PipRouter] callDidEnded - match: \(callUuid == callDetails?.uuid.uuidString)", subsystems: .call)
        if let callDetails, callUuid == callDetails.uuid.uuidString {
            Task { @MainActor in
                if isInPip {
                    cleanup()
                } else {
                    guard let presentedCallVC = presentedCallVC as? UINavigationController, let callVC = presentedCallVC.viewControllers.first as? CallViewController else {
                        log.warning("[PipRouter] callDidEnded - unexpected state, no CallViewController to dismiss", subsystems: .call)
                        return
                    }
                    dismissCallVC(callVC)
                }
            }

        } else {
            log.warning("[PipRouter] callDidEnded - condition failed, cleanup NOT called!", subsystems: .call)
        }
    }

//    public func expandPiP(completion: (() -> Void)? = nil) {
//        guard isInPip else {
//            log.warning("[PipRouter] expandPiP called but not in PiP mode", subsystems: .call)
//            completion?()
//            return
//        }
//
//        guard let delegate,
//              let callController,
//              let renderView else {
//            log.warning("[PipRouter] expandPiP failed - missing delegate, callController or renderView", subsystems: .call)
//            stopPip()
//            completion?()
//            return
//        }
//
//        // 1. Get/Create the CallViewController
//        guard let presentedCallVC = delegate.callViewController(self, for: callController) as? UINavigationController,
//              let callVC = presentedCallVC.viewControllers.first as? CallViewController else {
//            log.warning("[PipRouter] expandPiP failed - could not create CallViewController", subsystems: .call)
//            stopPip()
//            completion?()
//            return
//        }
//
//        // 2. Prepare CallVC (same as restoreUserInterfaceForPictureInPictureStopWithCompletionHandler)
//        callVC.willExpanedPiP()
//
//        // 3. Reattach video layer to CallVC
//        CATransaction.begin()
//        CATransaction.setDisableActions(true)
//
//        pipContentViewController?.detachVideoLayer()
//        if let previewLayer = renderView.previewLayer {
//            previewLayer.frame = callVC.remoteVideoView.bounds
//            renderView.layer.addSublayer(previewLayer)
//            renderView.frame = callVC.remoteVideoView.bounds
//        }
//        callVC.remoteVideoView.attach(with: renderView)
//
//        CATransaction.commit()
//
//        // 4. Present CallVC
//        self.presentedCallVC = presentedCallVC
//        delegate.pipRouter(self, wantsToShow: presentedCallVC) { [weak self] in
//            // 5. Stop PiP after presenting (this will trigger willStop/didStop delegates)
//            self?.pipController?.stopPictureInPicture()
//
//            // 6. Notify CallVC that expansion is complete
//            callVC.didExpanedPiP()
//
//            completion?()
//        }
//    }

    public func cleanup() {
        log.debug("[PipRouter] cleanup called, presentedCallVC: \(String(describing: presentedCallVC)), isInPip: \(isInPip)", subsystems: .call)
        let vcToDismiss = presentedCallVC
        callDetails = nil
        // Disable auto PiP first
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false

        // Invalidate content source - this is the key!
        pipController?.contentSource = nil

        // Stop PiP if active
        if isInPip {
            log.debug("[PipRouter] Stopping PiP during cleanup", subsystems: .call)
            pipController?.stopPictureInPicture()
        }

        // Detach video layer from PiP content
        pipContentViewController?.detachVideoLayer()
        isInPip = false
        errorMessage = nil
        if let vcToDismiss {
            vcToDismiss.dismiss(animated: true) { [weak self] in
                guard let self else {
                    return
                }
                // Release references
                let controllerToClean = callController
                callController = nil
                pipController = nil
                pipContentViewController = nil
                renderView = nil
                self.presentedCallVC = nil
            }
        } else {
            // Release references
            let controllerToClean = callController
            callController = nil
            pipController = nil
            pipContentViewController = nil
            renderView = nil
            self.presentedCallVC = nil
        }
        cancellables.removeAll()
        log.debug("[PipRouter] cleanup completed", subsystems: .call)
    }

    private func addCallMessageObserver() {
        log.debug("[PipRouter] add call message observer", subsystems: .call)
        CallManager.shared.messagePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                log.debug("[PipRouter] did receive call manager message: \(message)", subsystems: .call)
                guard let self else {
                    return
                }
                switch message {
                case .endCall(let uuid, let callId, let cid):
                    guard errorMessage == nil else {
                        return
                    }
                    self.callDidEnded(uuid.uuidString)
                case .createOutgoingCallError(let uuid, let error):
                    guard self.isInPip else {
                        return
                    }
                    errorMessage = message
                    stopPip()
                case .failedToConnect(let uuid):
                    guard self.isInPip else {
                        return
                    }
                    errorMessage = message
                    stopPip()
                case .startEndingCall:
                    break
                }
            }
            .store(in: &cancellables)
    }
}

extension PiPRouter: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.debug("[PipRouter] will start pip", subsystems: .call)
        isInPip = true
        if let presentedCallVC = self.presentedCallVC as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController {
            callVC.willMinimizedPiP()
        }

        guard let renderView, let pipContentViewController else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        renderView.previewLayer?.removeFromSuperlayer()
        renderView.previewLayer?.frame = pipContentViewController.view.bounds
        pipContentViewController.attachVideoLayer(renderView.previewLayer!)

        CATransaction.commit()

    }
    
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.debug("[PipRouter] did start pip", subsystems: .call)
//        presentedCallVC?.dismiss(animated: false)
        guard let presentedCallVC = self.presentedCallVC as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController else {
            return
        }
        callVC.didMinimizedPiP()
        callVC.dismiss(animated: false)
        self.presentedCallVC = nil
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, 
                                          failedToStartPictureInPictureWithError error: Error) {
        log.error("[PipRouter] failed to start pip with error: \(error)", subsystems: .call)
    }
    
    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.debug("[PipRouter] will stop pip", subsystems: .call)
        isInPip = false
        guard let callController,
              let renderView,
              let presentedCallVC = presentedCallVC as? UINavigationController ?? delegate?.callViewController(self, for: callController) as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController,
              let previewLayer = renderView.previewLayer else {
            log.warning("[PipRouter] unable to prepare for stop pip", subsystems: .call)
            renderView?.removeFromSuperview()
            return
        }

        callVC.willExpanedPiP()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
//        previewLayer.removeFromSuperlayer()
        pipContentViewController?.detachVideoLayer()
        previewLayer.frame = callVC.remoteVideoView.frame
        renderView.layer.addSublayer(previewLayer)
        renderView.frame = callVC.remoteVideoView.bounds
//        callVC.remoteVideoView.attach(with: renderView)
        CATransaction.commit()
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.debug("[PipRouter] did stop pip", subsystems: .call)
        guard let presentedCallVC = self.presentedCallVC as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController else {
            return
        }
        callVC.didExpanedPiP()
        if let errorMessage {
            callVC.didReceiveCallManagerMessage(errorMessage)
        }
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, 
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        log.debug("[PipRouter] restore user interface", subsystems: .call)
        guard let delegate,
              let callController,
              let presentedCallVC = delegate.callViewController(self, for: callController) as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController,
              let renderView else {
            completionHandler(true)
            log.warning("[PipRouter] unable to restore user interface", subsystems: .call)
            return
        }
        self.presentedCallVC = presentedCallVC
        callVC.remoteVideoView.attach(with: renderView)
        delegate.pipRouter(self, wantsToShow: presentedCallVC, completion: { [weak self] in
            self?.presentedCallVC = presentedCallVC
            completionHandler(true)
        })
    }
}
