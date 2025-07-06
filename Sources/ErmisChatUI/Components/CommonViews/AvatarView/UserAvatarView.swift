//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that shows a user avatar including an indicator of the user presence (online/offline).
open class UserAvatarView: _View, UIProvider {
    /// A view that shows the avatar image and online presence indicator.
    open private(set) lazy var presenceAvatarView: PresenceAvatarView = components
        .presenceAvatarView.init(with: .circular)
        .withoutAutoresizingMaskConstraints

    /// The data this view component shows.
    open var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    override open func setUpUI() {
        super.setUpUI()
        embed(presenceAvatarView)
    }

    override open func contentDidChanged() {
        presenceAvatarView.avatarView.loadImage(from: content?.imageURL,
                                                with: ImageLoaderOptions(
                                                    resize: .init(components.avatarThumbnailSize),
                                                    placeHolderString: content?.placeholderString,
                                                    placeholder: content?.placeholder
                                                )
        )

        presenceAvatarView.isOnlineIndicatorVisible = content?.isOnline ?? false
    }
}
// MARK: - Content
extension UserAvatarView {
    public
    struct Content {
        public var imageURL: URL?
        public var placeholderString: String?
        public var placeholder: UIImage?
        public var isOnline: Bool?

        public init(imageURL: URL? = nil,
                    placeholderString: String? = nil,
                    placeholder: UIImage? = nil,
                    isOnline: Bool? = nil) {
            self.imageURL = imageURL
            self.placeholderString = placeholderString
            self.placeholder = placeholder
            self.isOnline = isOnline
        }

        public init(with chatUser: ChatUser) {
            self.imageURL = chatUser.imageURL
            self.placeholderString = chatUser.name ?? chatUser.userId
            self.placeholder = nil
            self.isOnline = chatUser.isOnline
        }
    }
}
