//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChatUI

/// An enum represent picture in picture view position on screen when it minimized.
public enum PiPPosition {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public protocol PiPViewDelegate: AnyObject {
    func pipView(_ pipView: PiPView, didMoveTo position: PiPPosition)
    func pipViewDidTap(_ pipView: PiPView)
}

/// A view for showing PiP mode.
open class PiPView: UIView {
    var insets: UIEdgeInsets = .init(top: 64, left: 20, bottom: 64, right: 20)
    var cornerRadius: CGFloat = 32
    var position: PiPPosition = .bottomRight
    var animationDuration: TimeInterval = 0.27

    private var centerOrigin: CGPoint = .zero
    private var isDragging: Bool = false

    private lazy var tapGestureRecognizer: UITapGestureRecognizer = {
        UITapGestureRecognizer(target: self, action: #selector(didTapped(_:)))
    }()

    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        UIPanGestureRecognizer(target: self, action: #selector(didPanned(_:)))
    }()

    private var deviceOrientaionObserver: NSObjectProtocol?
    weak var delegate: PiPViewDelegate?

    /// The content view of PiP View. Add the view you want to show in PiP mode here.
    var contentView: UIView? {
        willSet {
            contentView?.isUserInteractionEnabled = true
            contentView?.translatesAutoresizingMaskIntoConstraints = true
        }

        didSet {
            if let contentView {
                contentView.isUserInteractionEnabled = false
                contentView.translatesAutoresizingMaskIntoConstraints = false
                addSubview(contentView)
                [
                    contentView.centerXAnchor.pin(equalTo: centerXAnchor),
                    contentView.centerYAnchor.pin(equalTo: centerYAnchor),
                    contentView.widthAnchor.pin(greaterThanOrEqualTo: widthAnchor),
                    contentView.heightAnchor.pin(greaterThanOrEqualTo: heightAnchor),
                    contentView.widthAnchor.pin(equalTo: contentView.heightAnchor, multiplier: contentView.bounds.width / contentView.bounds.height)
                ].forEach({ $0.isActive = true })
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let deviceOrientaionObserver {
            NotificationCenter.default.removeObserver(deviceOrientaionObserver)
        }
    }
    // MARK: - Setup
    func setUp() {
        layer.cornerRadius = cornerRadius
        isUserInteractionEnabled = true
        clipsToBounds = true

        addGestureRecognizer(tapGestureRecognizer)
        addGestureRecognizer(panGestureRecognizer)
        deviceOrientaionObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: nil) { [weak self] _ in
                guard let self, self.superview != nil else {
                    return
                }
                self.move(in: nil, to: self.position, animated: true)
            }
    }

    // MARK: - Action
    @objc func didTapped(_ sender: UITapGestureRecognizer) {
        delegate?.pipViewDidTap(self)
    }

    @objc func didPanned(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .possible:
            isDragging = true
        case .began:
            centerOrigin = center
            isDragging = true
        case .changed:
            let translation = sender.translation(in: superview)
            if isDragging {
                center = CGPoint(x: centerOrigin.x + translation.x,
                                 y: centerOrigin.y + translation.y)
            }
        case .ended, .recognized:
            defer {
                isDragging = false
            }
            if isDragging {
                guard let superview else {
                    return
                }
                let translation = sender.translation(in: superview)
                let bounds = superview.bounds
                let midX = bounds.width / 2
                let midY = bounds.height / 2

                let onLeft = centerOrigin.x + translation.x < midX
                let onTop = centerOrigin.y + translation.y < midY

                var newPosition: PiPPosition = .bottomRight
                switch (onTop, onLeft) {
                case (true, true):
                    newPosition = .topLeft
                case (true, false):
                    newPosition = .topRight
                case (false, true):
                    newPosition = .bottomLeft
                case (false, false):
                    newPosition = .bottomRight
                }

                move(in: nil, to: newPosition) { _ in
                    self.delegate?.pipView(self, didMoveTo: newPosition)
                }
            }
        case .cancelled:
            isDragging = false
        case .failed:
            isDragging = false
        }
    }

    func move(in view: UIView?,
              targetSize: CGSize? = nil,
              animated: Bool = false,
              completion: ((Bool) -> Void)? = nil) {
        move(in: view, to: position, animated: animated, completion: completion)
    }

    func move(in view: UIView?,
              to position: PiPPosition,
              targetSize: CGSize? = nil,
              animated: Bool = false,
              completion: ((Bool) -> Void)? = nil) {
        let updateTargetFrameBlock = { [weak self] in
            guard let self else {
                return
            }
            let targetFrame = self.targetFrame(for: position, in: view, targetSize: targetSize)
            self.frame = targetFrame
        }

        if animated {
            UIView.animate(withDuration: animationDuration, animations: updateTargetFrameBlock) { completed in
                self.position = position
                completion?(completed)
            }
        } else {
            updateTargetFrameBlock()
            self.position = position
            completion?(true)
        }
    }
    // MARK: - Helper
    private func targetFrame(for position: PiPPosition,
                             in view: UIView?,
                             targetSize: CGSize?) -> CGRect {
        guard let view = view ?? superview else {
            return .zero
        }
        let targetSize = targetSize ?? frame.size

        let minDeviceBounds = min(view.bounds.width, view.bounds.height)
        let maxDeviceBounds = max(view.bounds.width, view.bounds.height)

        let superViewWidth = UIDevice.current.orientation.isLandscape ? maxDeviceBounds : minDeviceBounds
        let superViewHeight = UIDevice.current.orientation.isLandscape ? minDeviceBounds : maxDeviceBounds

        var origin: CGPoint = .zero

        switch position {
        case .topLeft:
            origin = CGPoint(x: insets.left + view.safeAreaInsets.left,
                             y: insets.top + view.safeAreaInsets.top)
        case .topRight:
            origin = CGPoint(x: superViewWidth - insets.right - view.safeAreaInsets.right - targetSize.width,
                             y: insets.top + view.safeAreaInsets.top)
        case .bottomLeft:
            origin = CGPoint(x: insets.left + view.safeAreaInsets.left,
                             y: superViewHeight - insets.bottom - view.safeAreaInsets.bottom - targetSize.height)
        case .bottomRight:
            origin = CGPoint(x: superViewWidth - insets.right - view.safeAreaInsets.right - targetSize.width,
                             y: superViewHeight - insets.bottom - view.safeAreaInsets.bottom - targetSize.height)
        }

        return CGRect(origin: origin, size: targetSize)
    }
}
