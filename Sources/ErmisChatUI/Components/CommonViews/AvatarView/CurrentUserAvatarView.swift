//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A UIControl subclass that is designed to show the avatar of the currently logged in user.
///
/// It uses `CurrentUserController` for its input data and is able to update the avatar automatically based
/// on the currently logged-in user.
///
open class CurrentUserAvatarView: _Control, UIProvider {
    /// `ErmisChat`'s controller that observe the currently logged-in user.
    open var controller: CurrentUserController? {
        didSet {
            controller?.delegate = self
            controller?.synchronize()
            updateContentIfNeeded()
        }
    }

    /// The view that shows the current user's avatar.
    open private(set) lazy var avatarView: AvatarView = components
        .avatarView.init(style: avatarStyle)
        .withoutAutoresizingMaskConstraints

    public var avatarStyle: AvatarStyle = .circular {
        didSet {
            avatarView.style = avatarStyle
        }
    }

    public required init(avatarStyle: AvatarStyle) {
        self.avatarStyle = avatarStyle
        super.init(frame: .zero)
    }

    @MainActor required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = .clear
        avatarView.imageView.backgroundColor = theme.colors.surface
    }

    override open var isEnabled: Bool {
        get { super.isEnabled }
        set { super.isEnabled = newValue; updateContentIfNeeded() }
    }

    override open var isHighlighted: Bool {
        get { super.isHighlighted }
        set { super.isHighlighted = newValue; updateContentIfNeeded() }
    }

    override open var isSelected: Bool {
        get { super.isSelected }
        set { super.isSelected = newValue; updateContentIfNeeded() }
    }

    override open func setUp() {
        super.setUp()
        avatarView.isUserInteractionEnabled = false
    }

    override open func setUpUI() {
        super.setUpUI()

        heightAnchor.pin(equalToConstant: 32).isActive = true
        widthAnchor.pin(equalTo: heightAnchor).isActive = true

        embed(avatarView)
        avatarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        avatarView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @objc override open func contentDidChanged() {
        let currentUserImageUrl = controller?.currentUser?.imageURL
        let currentUserName = controller?.currentUser?.name

        avatarView.loadImage(from: currentUserImageUrl,
                             with: ImageLoaderOptions(
                                resize: ImageResize(components.avatarThumbnailSize),
                                placeHolderString: currentUserName
                             ))
        alpha = state == .normal ? 1 : 0.5
    }
}

// MARK: - CurrentUserControllerDelegate

extension CurrentUserAvatarView: CurrentUserControllerDelegate {
    public func currentUserController(
        _ controller: CurrentUserController,
        didChangeCurrentUser: EntityChange<CurrentChatUser>
    ) {
        updateContentIfNeeded()
    }
}
