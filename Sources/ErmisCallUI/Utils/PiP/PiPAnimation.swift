//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

enum PiPAnimationType {
    case minimized
    case expanded
}

/// Animation when show/hide PiP View.
class PiPAnimation: NSObject {
    var pipViewSize: CGSize
    let ratio: CGFloat
    let duration: TimeInterval
    let animationType: PiPAnimationType
    weak var pipViewDelegate: PiPViewDelegate?

    // Scale of pip view width with main screen.
    private let scale: CGFloat = 0.3

    init(duration: TimeInterval = 0.27,
         pipViewSize: CGSize = CGSize(width: 120, height: 160),
         ratio: CGFloat = 16.0 / 9.0,
         animationType: PiPAnimationType = .minimized,
         pipViewDelegate: PiPViewDelegate?) {
        self.duration = duration
        self.ratio = ratio
        self.pipViewSize = pipViewSize
        self.animationType = animationType
        self.pipViewDelegate = pipViewDelegate
    }

    private func minimizedAmimation(context: UIViewControllerContextTransitioning) {
        let windows = UIApplication.shared.connectedScenes.reduce([UIWindow](), { partialResult, scene in
            var windows = (scene as? UIWindowScene)?.windows ?? []
            windows.append(contentsOf: partialResult)
            return windows
        })

        guard let keyWindow = windows.last(where: { $0.isKeyWindow}),
              let fromVC = context.viewController(forKey: .from) else {
            context.completeTransition(false)
            return
        }

        if let nvc = fromVC as? UINavigationController, let pipable = nvc.viewControllers.first as? PiPable {
            pipable.willMinimizedPiP()
        }
        fromVC.willMove(toParent: nil)
        context.completeTransition(true)
        fromVC.removeFromParent()

        let deviceRatio = UIScreen.main.bounds.height / UIScreen.main.bounds.width
        // Change frame ratio to pip ratio for scale animation.
        var newFrame: CGRect
        if deviceRatio < ratio {
            newFrame = .init(origin: .zero, size: CGSize(width: fromVC.view.bounds.height / ratio,
                                                         height: fromVC.view.bounds.height))
        } else {
            newFrame = .init(origin: .zero, size: CGSize(width: fromVC.view.bounds.width,
                                                         height: fromVC.view.bounds.width * ratio))
        }
        let pipView = PiPView(frame: newFrame)

        pipView.animationDuration = duration
        pipView.contentView = fromVC.view
        pipView.delegate = pipViewDelegate

        keyWindow.addSubview(pipView)

        if !UIDevice.current.isMac {
            let width = pipView.frame.size.min * scale
            let height = width / ratio
            pipViewSize = CGSize(width: width,
                                 height: height)
        }
        let tranform = CGAffineTransform(scaleX: scale, y: scale)
        let targetSize = pipViewSize
        pipView.cornerRadius = pipView.cornerRadius / scale
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) {
            pipView.transform = tranform
            pipView.move(in: keyWindow, targetSize: targetSize)
        }

        animator.addCompletion { position in
            if let nvc = fromVC as? UINavigationController, let pipable = nvc.viewControllers.first as? PiPable {
                pipable.didMinimizedPiP()
            }
            fromVC.view.frame.origin = .zero
            fromVC.dismiss(animated: false, completion: nil)
        }
        animator.startAnimation()
    }

    private func expandedAnimation(context: UIViewControllerContextTransitioning) {
        let windows = UIApplication.shared.connectedScenes.reduce([UIWindow](), { partialResult, scene in
            var windows = (scene as? UIWindowScene)?.windows ?? []
            windows.append(contentsOf: partialResult)
            return windows
        })

        guard let keyWindow = windows.last(where: { $0.isKeyWindow}),
              let toVC = context.viewController(forKey: .to),
              let snapshot = toVC.view.snapshotView(afterScreenUpdates: true) else {
            context.completeTransition(false)
            return
        }

        if let nvc = toVC as? UINavigationController, let pipable = nvc.viewControllers.first as? PiPable {
            pipable.willExpanedPiP()
        }

        guard let pipView = toVC.view.superview as? PiPView else {
            return
        }
        context.containerView.addSubview(toVC.view)
        context.containerView.addSubview(snapshot)
        toVC.view.isHidden = true

        toVC.additionalSafeAreaInsets = keyWindow.safeAreaInsets
        pipView.contentView = nil
        pipView.removeFromSuperview()

        snapshot.frame = pipView.frame

        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) {
            if keyWindow.bounds.width > keyWindow.bounds.height, !UIDevice.current.isMac {
                snapshot.transform = CGAffineTransform(rotationAngle: .pi / 2)
            }
            snapshot.frame = context.finalFrame(for: toVC)
        }

        animator.addCompletion { position in
            toVC.additionalSafeAreaInsets = .zero
            toVC.view.frame = context.finalFrame(for: toVC)
            toVC.view.isHidden = false

            snapshot.removeFromSuperview()
            if let nvc = toVC as? UINavigationController, let pipable = nvc.viewControllers.first as? PiPable {
                pipable.didExpanedPiP()
            }
            context.completeTransition(!context.transitionWasCancelled)
        }

        animator.startAnimation()
    }
}
// MARK: - UIViewControllerAnimatedTransitioning
extension PiPAnimation: UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        return duration
    }
    
    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        switch animationType {
        case .minimized:
            minimizedAmimation(context: transitionContext)
        case .expanded:
            expandedAnimation(context: transitionContext)
        }
    }
}
