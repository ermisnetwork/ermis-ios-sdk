//
// Copyright 2025 Ermis Inc.
//

import ErmisCall
import UIKit

public protocol PiPRouterDelegate: AnyObject {
    func pipRouter(_ router: PiPRouter, wantsToShow callVC: UIViewController, completion: (() -> Void)?)
    func pipRouter(_ router: PiPRouter, wantsToDismiss callVC: UIViewController, completion: (() -> Void)?)
    func pipRouter(_ router: PiPRouter, wantsToMinimize callVC: UIViewController, completion: (() -> Void)?)
    func pipRouter(_ router: PiPRouter, wantsToExpand callVC: UIViewController, completion: (() -> Void)?)
}
/// A class for enter/exit PiP mode.
public class PiPRouter: NSObject {
    public var pipCallVC: UIViewController?
    public var presentedCallVC: UIViewController?

    public
    weak var delegate: PiPRouterDelegate?

    private var operationQueue: OperationQueue = .main

    /// Show new call screen
    ///
    /// - Parameters:
    ///  - callVC: The new call viewcontroller instance need to show.
    ///  - completion: The completion handler closure when finish.
    public func showCallVC(_ callVC: UIViewController, completion: (() -> Void)? = nil) {
        callVC.transitioningDelegate = self
        if let presentedCallVC {
            dismissCallVC(presentedCallVC)
        }

        let operation = PiPOperation(type: .show, callVC: callVC, router: self) { [weak self] in
            self?.presentedCallVC = callVC
            if callVC == self?.pipCallVC {
                self?.pipCallVC = nil
            }
            completion?()
        }

        operationQueue.addOperation(operation)
    }

    /// Hide call view controller.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to remove.
    ///  - completion: The completion handler closure when finish.
    public func dismissCallVC(_ callVC: UIViewController, completion: (() -> Void)? = nil) {
        if let pipCallVC, pipCallVC == callVC {
            expandCallVC(callVC)
        }
        callVC.transitioningDelegate = self
        let operation = PiPOperation(type: .dismiss, callVC: callVC, router: self) { [weak self] in
            if self?.presentedCallVC == callVC {
                self?.presentedCallVC = nil
            }
            completion?()
        }
        operationQueue.addOperation(operation)
    }

    /// Enter PiP mode.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to enter PiP.
    ///  - completion: The completion handler closure when finish.
    public func minimizeCallVC(_ callVC: UIViewController, completion: (() -> Void)? = nil) {
        callVC.transitioningDelegate = self
        let operation = PiPOperation(type: .minimize, callVC: callVC, router: self) { [weak self] in
            self?.pipCallVC = callVC
            if callVC == self?.presentedCallVC {
                self?.presentedCallVC = nil
            }
            completion?()
        }
        operationQueue.addOperation(operation)
    }

    /// Exit PiP mode.
    ///
    /// - Parameters:
    ///  - callVC: The call viewcontroller to exit PiP mode
    ///  - completion: The completion handler closure when finish.
    public func expandCallVC(_ callVC: UIViewController, completion: (() -> Void)? = nil) {
        callVC.transitioningDelegate = self
        let operation = PiPOperation(type: .expand, callVC: callVC, router: self) { [weak self] in
            if callVC == self?.pipCallVC {
                self?.pipCallVC = nil
            }
            self?.presentedCallVC = callVC
            completion?()
        }
        operationQueue.addOperation(operation)
    }
}
// MARK: - UIViewControllerTransitioningDelegate
extension PiPRouter: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        return PiPAnimation(duration: 0.27, animationType: .expanded, pipViewDelegate: nil)
    }

    public func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        return PiPAnimation(duration: 0.27, animationType: .minimized, pipViewDelegate: self)
    }
}
// MARK: - PipViewDelegate
extension PiPRouter: PiPViewDelegate {
    public func pipView(_ pipView: PiPView, didMoveTo position: PiPPosition) {

    }

    public func pipViewDidTap(_ pipView: PiPView) {
        guard let pipCallVC else { return }
        expandCallVC(pipCallVC)
    }
}
