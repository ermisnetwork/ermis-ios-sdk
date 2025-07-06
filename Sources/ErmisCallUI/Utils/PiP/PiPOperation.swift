//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

enum PiPOperationType {
    case minimize
    case expand
    case show
    case dismiss
}

class PiPOperation: Operation {
    private var _finished = false
    private var _executing = false
    private let stateQueue = DispatchQueue(label: "network.ermis.pip-operation",
                                           attributes: .concurrent)
    var type: PiPOperationType
    var callVC: UIViewController
    var router: PiPRouter
    var completion: (() -> Void)?

    init(type: PiPOperationType, callVC: UIViewController, router: PiPRouter, completion: (() -> Void)? = nil) {
        self.type = type
        self.callVC = callVC
        self.router = router
        self.completion = completion
        super.init()
    }

    override var isExecuting: Bool {
        get {
            stateQueue.sync {
                _executing
            }
        }
        set {
            willChangeValue(for: \.isExecuting)
            stateQueue.async(flags: .barrier) {
                self._executing = newValue
            }
            didChangeValue(for: \.isExecuting)
        }
    }

    override var isFinished: Bool {
        get {
            stateQueue.sync {
                _finished
            }
        }
        set {
            willChangeValue(for: \.isFinished)
            stateQueue.async(flags: .barrier) {
                self._finished = newValue
            }
            didChangeValue(for: \.isFinished)
        }
    }

    override func start() {
        if isCancelled {
            isFinished = true
            return
        }
        isExecuting = true
        main()
    }

    override func main() {
        switch type {
        case .minimize:
            router.delegate?.pipRouter(router, wantsToMinimize: callVC, completion: {
                self.isFinished = true
                self.completion?()
            })
        case .expand:
            router.delegate?.pipRouter(router, wantsToExpand: callVC, completion: {
                self.isFinished = true
                self.completion?()
            })
        case .show:
            router.delegate?.pipRouter(router, wantsToShow: callVC, completion: {
                self.isFinished = true
                self.completion?()
            })
        case .dismiss:
            router.delegate?.pipRouter(router, wantsToDismiss: callVC, completion: {
                self.isFinished = true
                self.completion?()
            })
        }
    }
}
