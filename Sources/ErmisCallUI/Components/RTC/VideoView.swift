//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import ErmisChat
import ErmisChatUI

open class VideoView: _View, UIProvider, RemoteImageDisplayable {
    public var imageView: UIImageView {
        return backgroundImageView
    }

    public private(set) lazy var blurEffectView: UIVisualEffectView = {
        let blurEffect = UIBlurEffect(style: .dark)
        return UIVisualEffectView(effect: blurEffect)
            .withoutAutoresizingMaskConstraints
    }()
    public private(set) lazy var videoView = UIView()
        .withoutAutoresizingMaskConstraints

    public private(set) lazy var backgroundImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    public override func setUp() {
        super.setUp()
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        videoView.backgroundColor = .clear
    }

    public override func setUpUI() {
        super.setUpUI()
        addSubviews([
            backgroundImageView,
            blurEffectView,
            videoView
        ])

        backgroundImageView.pin(to: self)
        blurEffectView.pin(to: self)
        videoView.pin(to: self)
    }

    public override func setUpTheme() {
        super.setUpTheme()
        backgroundColor = theme.colors.surface
    }

    public override func contentDidChanged() {
        super.contentDidChanged()
        guard let content else {
            return
        }

        if content.isMirror {
            transform = CGAffineTransform.init(scaleX: -1, y: 1)
        } else {
            transform = .identity
        }

        loadImage(from: content.imageURL,
                  with: ImageLoaderOptions(
            resize: .init(components.avatarThumbnailSize),
            placeHolderString: content.title
        ))
    }
}

extension VideoView {
    public struct Content {
        let title: String
        let imageURL: URL?
        let isMirror: Bool
        let member: ChannelMember

        public init(with member: ChannelMember, isMirror: Bool = false) {
            self.title = member.displayName
            self.imageURL = member.imageURL
            self.member = member
            self.isMirror = isMirror
        }
    }
}
