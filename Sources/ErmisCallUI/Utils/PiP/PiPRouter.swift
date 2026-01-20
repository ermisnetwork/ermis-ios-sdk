//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import ErmisCall
import UIKit
import AVKit

public protocol PiPRouterDelegate: AnyObject {
    func pipRouter(_ router: PiPRouter, wantsToShow callVC: UIViewController, completion: (() -> Void)?)
    func callViewController(_ router: PiPRouter, for callController: CallController) -> UIViewController
//    func pipRouter(_ router: PiPRouter, wantsToDismiss callVC: UIViewController, completion: (() -> Void)?)
//    func pipRouter(_ router: PiPRouter, wantsToMinimize callVC: UIViewController, completion: (() -> Void)?)
//    func pipRouter(_ router: PiPRouter, wantsToExpand callVC: UIViewController, completion: (() -> Void)?)
}
/// A class for enter/exit PiP mode.
public class PiPRouter: NSObject {
    public var pipController: AVPictureInPictureController?
    public var callController: CallController?
    public weak var renderView: VideoRenderView?
    public var pipContentViewController: PiPVideoCallViewController?
    public weak var delegate: PiPRouterDelegate?
    public weak var presentedCallVC: UIViewController?

    public var isInPip: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    @MainActor public func setup(with callController: CallController) {
        guard let call  = callController.call else {
            log.warning("[PipRouter] Failed to setup PiP: callController isNil: \(callController == nil), delegate isNil: \(delegate == nil)")
            return
        }
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
    @MainActor public func showCallVC(_ callController: CallController, completion: (() -> Void)? = nil) {
        if isInPip {
            stopPip()
            return
        }
        setup(with: callController)
        guard let delegate else {
            fatalError("[PipRouter] Delegate is not set")
        }
        let vc = delegate.callViewController(self, for: callController)
        guard let vc = vc as? UINavigationController,
              let callVC = vc.viewControllers.first as? CallViewController else {
            return
        }

        if let renderView = callController.call?.renderView {
            callVC.remoteVideoView.attach(with: renderView)
        }
        delegate.pipRouter(self, wantsToShow: vc, completion: { [weak self] in
            self?.presentedCallVC = vc
            completion?()
        })
    }

    /// Hide call view controller.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to remove.
    ///  - completion: The completion handler closure when finish.
    public func dismissCallVC(_ callVC: CallViewController, completion: (() -> Void)? = nil) {
        self.presentedCallVC?.dismiss(animated: true, completion: { [weak self] in
            self?.cleanup()
            completion?()
        })
    }

    /// Enter PiP mode.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to enter PiP.
    ///  - completion: The completion handler closure when finish.
    @MainActor public func startPip(completion: (() -> Void)? = nil) {
        guard !isInPip else {
            log.warning("[PipRouter] Start pip failed - already in pip")
            return
        }
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
    public func stopPip(completion: (() -> Void)? = nil) {
        guard let pipController else {
            return
        }
        defer {
            log.debug("[PipRouter] Begin stop pip")
            pipController.stopPictureInPicture()
        }
//        guard isInPip else {
//            log.warning("[PipRouter] Stop pip failed - already exit pip")
//            return
//        }
    }

    @MainActor public func cleanup() {
        // Disable auto PiP first
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false

        // Invalidate content source - this is the key!
        pipController?.contentSource = nil

        // Stop PiP if active
        if isInPip {
            pipController?.stopPictureInPicture()
        }

        // Detach video layer from PiP content
        pipContentViewController?.detachVideoLayer()

        // Release references
        pipController?.delegate = nil
        pipController = nil
        pipContentViewController = nil
        callController = nil
        renderView = nil

        // Dismiss the call view controller if presented
        presentedCallVC?.dismiss(animated: true)
        presentedCallVC = nil
    }

}

extension PiPRouter: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.debug("[PipRouter] will start pip")
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
        log.debug("[PipRouter] did start pip")
//        presentedCallVC?.dismiss(animated: false)
        guard let presentedCallVC = self.presentedCallVC as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController else {
            return
        }
        callVC.didMinimizedPiP()

    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, 
                                          failedToStartPictureInPictureWithError error: Error) {
        log.debug("[PipRouter] failed to start pip with error: \(error)")
    }
    
    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.debug("[PipRouter] will stop pip")
        guard let callController,
              let renderView,
              let presentedCallVC = presentedCallVC as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController,
              let previewLayer = renderView.previewLayer else {
            log.warning("[PipRouter] unable to prepare for stop pip")
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
        log.debug("[PipRouter] did stop pip")
        guard let presentedCallVC = self.presentedCallVC as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController else {
            return
        }
        callVC.didExpanedPiP()
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, 
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if let renderView,
           let presentedCallVC = self.presentedCallVC as? UINavigationController,
           let callVC = presentedCallVC.viewControllers.first as? CallViewController {
            callVC.remoteVideoView.attach(with: renderView)
            completionHandler(true)
            return
        }
        log.debug("[PipRouter] restore user interface")
        guard let delegate,
              let callController,
              let presentedCallVC = delegate.callViewController(self, for: callController) as? UINavigationController,
              let callVC = presentedCallVC.viewControllers.first as? CallViewController,
              let renderView else {
            completionHandler(true)
            log.warning("[PipRouter] unable to restore user interface")
            return
        }
        callVC.remoteVideoView.attach(with: renderView)
        delegate.pipRouter(self, wantsToShow: presentedCallVC, completion: { [weak self] in
            self?.presentedCallVC = presentedCallVC
            completionHandler(true)
        })
    }
}
