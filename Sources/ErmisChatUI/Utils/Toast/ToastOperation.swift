//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

class ToastOperation: Foundation.Operation {
    @objc private enum State: Int {
        case ready
        case executing
        case finished
    }

    private var _state: State = .ready
    private let stateQueue = DispatchQueue(label: "network.ermis.toast.stateQueue_\(ProcessInfo.processInfo.globallyUniqueString)",
                                           attributes: .concurrent)
    @objc private dynamic var state: State {
        get {
            return stateQueue.sync {
                _state
            }
        } set {
            stateQueue.sync(flags: .barrier) {
                _state = newValue
            }
        }
    }
    //
    let margin: UIEdgeInsets = UIEdgeInsets(
        top: 16,
        left: 16,
        bottom: 16,
        right: 16
    )
    let animationDuration: TimeInterval = 0.16
    let timeBetweenToasts: TimeInterval = 0
    private var containerView: UIView
    private var toastView: UIView
    private var duration: TimeInterval
    private var position: ToastPosition
    private var additionalMargin: CGFloat
    private var completion: (() -> Void)?
    private var timer: Timer?

    init(
        containerView: UIView,
        toastView: UIView,
        duration: TimeInterval,
        position: ToastPosition,
        additionalMargin: CGFloat,
        completion: (() -> Void)? = nil
    ) {
        self.containerView = containerView
        self.toastView = toastView
        self.duration = duration
        self.position = position
        self.additionalMargin = additionalMargin
        self.completion = completion
    }


    override var isReady: Bool {
        return super.isReady && state == .ready
    }

    override var isExecuting: Bool {
        return state == .executing
    }

    override var isFinished: Bool {
        return state == .finished
    }

    override var isAsynchronous: Bool {
        return true
    }

    @objc class var keyPathsForValuesAffectingIsReady: Set<String> {
        return [#keyPath(state)]
    }

    @objc class var keyPathsForValuesAffectingIsExecuting: Set<String> {
        return [#keyPath(state)]
    }

    @objc class var keyPathsForValuesAffectingIsFinished: Set<String> {
        return [#keyPath(state)]
    }

    override func start() {
        if isCancelled {
            finish()
            return
        }
        state = .executing
        main()
    }

    override func main() {
        self.show({ [weak self] in
            guard let self else { return }
            invalidateTimer()
            startTimer()
        })
    }

    func finish() {
        self.state = .finished
    }
    // MARK: -
    private func show(_ completion: (() -> Void)? = nil) {
        toastView.alpha = 0
        containerView.addSubview(toastView)
        toastView.translatesAutoresizingMaskIntoConstraints = false
        switch position {
        case .top:
            NSLayoutConstraint.activate([
                toastView.leadingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.leadingAnchor,
                                                   constant: margin.left),
                toastView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor,
                                               constant: margin.top + additionalMargin),
                toastView.trailingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.trailingAnchor,
                                                    constant: -margin.right),
                toastView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.safeAreaLayoutGuide.bottomAnchor,
                                                  constant: -margin.bottom)
            ])
        case .middle:
            NSLayoutConstraint.activate([
                toastView.leadingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.leadingAnchor,
                                                   constant: margin.left),
                toastView.topAnchor.constraint(greaterThanOrEqualTo: containerView.safeAreaLayoutGuide.topAnchor,
                                               constant: margin.top),
                toastView.trailingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.trailingAnchor,
                                                    constant: -margin.right),
                toastView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.safeAreaLayoutGuide.bottomAnchor,
                                                  constant: -margin.bottom),
                toastView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
            ])
        case .bottom:
            NSLayoutConstraint.activate([
                toastView.leadingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.leadingAnchor,
                                                   constant: margin.left),
                toastView.topAnchor.constraint(greaterThanOrEqualTo: containerView.safeAreaLayoutGuide.topAnchor,
                                               constant: margin.top),
                toastView.trailingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.trailingAnchor,
                                                    constant: -margin.right),
                toastView.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor,
                                                  constant: -margin.bottom - additionalMargin)
            ])

        }
        UIView.animate(withDuration: animationDuration,
                       delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction],
                       animations: {
            self.toastView.alpha = 1
        }, completion: { _ in
            completion?()
        })
    }

    private func hide() {
        UIView.animate(withDuration: animationDuration,
                       delay: 0,
                       options: [.curveEaseIn, .beginFromCurrentState],
                       animations: {
            self.toastView.alpha = 0
        }, completion: { _ in
            self.toastView.removeFromSuperview()
            DispatchQueue.main.asyncAfter(deadline: .now() + self.timeBetweenToasts, execute: {
                self.finish()
                self.completion?()
            })
        })
    }
}
// MARK: - Timer
extension ToastOperation {
    private func startTimer() {
        let timer = Timer(timeInterval: duration,
                          target: self,
                          selector: #selector(timerDidFire(_:)),
                          userInfo: nil,
                          repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc
    private func timerDidFire(_ timer: Timer) {
        invalidateTimer()
        hide()
    }
}
