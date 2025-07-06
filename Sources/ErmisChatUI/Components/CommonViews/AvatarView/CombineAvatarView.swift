//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class CombineAvatarView: _View, UIProvider {
    open private(set) lazy var firstAvatarImageView = components
        .avatarView
        .init(style: bottomLeftAvatarStyle)
        .withoutAutoresizingMaskConstraints
    open private(set) lazy var secondAvatarImageView = components
        .avatarView
        .init(style: topRightAvatarStyle)
        .withoutAutoresizingMaskConstraints

    public var bottomLeftAvatarStyle: AvatarStyle = .circular {
        didSet {
            firstAvatarImageView.style = bottomLeftAvatarStyle
        }
    }
    public var topRightAvatarStyle: AvatarStyle = .circular {
        didSet {
            secondAvatarImageView.style = topRightAvatarStyle
        }
    }

    public var content: [ChatUser] = [] {
        didSet {
            updateContentIfNeeded()
        }
    }

    public required init(bottomLeftAvatarStyle: AvatarStyle, topRightAvatarStyle: AvatarStyle) {
        super.init(frame: .zero)
        self.bottomLeftAvatarStyle = bottomLeftAvatarStyle
        self.topRightAvatarStyle = topRightAvatarStyle
    }

    @MainActor public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override func setUp() {
        super.setUp()
        clipsToBounds = true
        firstAvatarImageView.layer.borderWidth = 1.5

        switch bottomLeftAvatarStyle {
        case .cornerRadius(let cornerRadius):
            firstAvatarImageView.layer.cornerRadius = cornerRadius
        case .circular:
            break
        }

        switch topRightAvatarStyle {
        case .cornerRadius(let cornerRadius):
            secondAvatarImageView.layer.cornerRadius = cornerRadius
        case .circular:
            break
        }
    }

    open override func setUpUI() {
        super.setUpUI()
        addSubviews([
            secondAvatarImageView,
            firstAvatarImageView,
        ])

        firstAvatarImageView.pin(anchors: [.leading], to: self, contant: -1.5)
        firstAvatarImageView.pin(anchors: [.bottom], to: self, contant: 1.5)
        firstAvatarImageView.pin(anchors: [.width, .height], to: self, multipler: 0.7)

        secondAvatarImageView.pin(anchors: [.top, .trailing], to: self)
        secondAvatarImageView.pin(anchors: [.width, .height], to: self, multipler: 0.6)
    }

    open override func contentDidChanged() {
        firstAvatarImageView.loadImage(from: content.first?.imageURL,
                                       with: ImageLoaderOptions(
                                        resize: .init(components.avatarThumbnailSize),
                                        placeHolderString: content.first?.displayName,
                                        placeholder: nil
                                       ))

        secondAvatarImageView.loadImage(from: content.last?.imageURL,
                                        with: ImageLoaderOptions(
                                            resize: .init(components.avatarThumbnailSize),
                                            placeHolderString: content.last?.displayName,
                                            placeholder: nil
                                        ))
    }

    func cancelLoading() {
        firstAvatarImageView.cancelLoading()
        secondAvatarImageView.cancelLoading()
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        switch bottomLeftAvatarStyle {
        case .circular:
            firstAvatarImageView.layer.cornerRadius = firstAvatarImageView.bounds.width / 2
        case .cornerRadius(let cGFloat):
            break
        }

        switch topRightAvatarStyle {
        case .circular:
            secondAvatarImageView.layer.cornerRadius = secondAvatarImageView.bounds.width / 2
        case .cornerRadius(let cGFloat):
            break
        }
    }

    open override func setUpTheme() {
        super.setUpTheme()
        firstAvatarImageView.layer.borderColor = theme.colors.surface.cgColor
    }
}
