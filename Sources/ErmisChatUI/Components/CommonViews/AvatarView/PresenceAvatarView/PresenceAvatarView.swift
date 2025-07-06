//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that shows a user avatar including an indicator of the user presence (online/offline).
open class PresenceAvatarView: _View, ComponentsProvider {
    /// A view that shows the avatar image
    open private(set) lazy var avatarView: AvatarView = components
        .avatarView.init(style: avatarStyle)
        .withoutAutoresizingMaskConstraints

    /// A view indicating whether the user this view represents is online.
    ///
    /// The type of `onlineIndicatorView` is UIView & MaskProviding in Components.
    /// Xcode is failing to compile due to `Segmentation fault: 11` when used here.
    open private(set) lazy var onlineIndicatorView: UIView = components
        .onlineIndicatorView.init()
        .withoutAutoresizingMaskConstraints

    open var avatarStyle: AvatarStyle = .circular {
        didSet {
            avatarView.style = avatarStyle
        }
    }

    /// Bool to determine if the indicator should be shown.
    open var isOnlineIndicatorVisible: Bool = false {
        didSet {
            onlineIndicatorView.isVisible = isOnlineIndicatorVisible
            setUpMask(indicatorVisible: isOnlineIndicatorVisible)
        }
    }

    public required init(with avatarStyle: AvatarStyle) {
        self.avatarStyle = avatarStyle
        super.init(frame: .zero)
    }
    
    @MainActor public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func setUpTheme() {
        super.setUpTheme()
        onlineIndicatorView.isHidden = true
    }

    override open func setUpUI() {
        super.setUpUI()
        embed(avatarView)
        // Add online indicator view
        addSubview(onlineIndicatorView)

        onlineIndicatorView.topAnchor
            .pin(equalTo: topAnchor, constant: 1)
            .isActive = true
        onlineIndicatorView.rightAnchor
            .pin(equalTo: rightAnchor, constant: -1)
            .isActive = true
        onlineIndicatorView.widthAnchor
            .pin(equalTo: widthAnchor, multiplier: 0.2)
            .isActive = true
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        setUpMask(indicatorVisible: isOnlineIndicatorVisible)
    }

    /// Creates space for indicator view in avatar view by masking path provided by the indicator view.
    /// - Parameter visible: Bool to determine if the indicator should be shown. The avatar view won't be masked if the indicator is not visible.
    open func setUpMask(indicatorVisible: Bool) {
        guard
            indicatorVisible,
            let path = (onlineIndicatorView as? MaskProviding)?.maskingPath?.mutableCopy()
        else { return avatarView.layer.mask = nil }

        path.addRect(bounds)
        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd

        avatarView.layer.mask = maskLayer
    }
}
