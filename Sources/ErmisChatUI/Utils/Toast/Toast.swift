//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

public enum ToastPosition {
    case top
    case middle
    case bottom
}

public class ToastManager {

    private static var operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ermis_toast_queue"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        queue.underlyingQueue = .main
        return queue
    }()

    static public func showToast(title: String?,
                   message: String?,
                   style: ToastStyle = .neutral,
                   duration: TimeInterval = 4,
                   position: ToastPosition = .bottom,
                   additionalMargin: CGFloat = 0,
                   showIcon: Bool  = true,
                   in containerView: UIView) {
        let toastView = Components.default.toastView.init()
        toastView.content = .init(showIcon: showIcon,
                                  title: title,
                                  message: message,
                                  style: style)
        let toastOperation = ToastOperation(
            containerView: containerView,
            toastView: toastView,
            duration: duration,
            position: position,
            additionalMargin: additionalMargin,
            completion: nil
        )
        DispatchQueue.main.async {
            Self.operationQueue.addOperation(toastOperation)
        }
    }

    static public func removeAllToast() {
        operationQueue.cancelAllOperations()
    }
}

