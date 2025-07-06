//
// Copyright 2025 Ermis Inc.
//

import UIKit
import Combine

public enum AvatarStyle {
    case circular
    case cornerRadius(CGFloat)
}

/// A view that displays the avatar image. By default a circular image.
open class AvatarView: _ImageView, ComponentsProvider, RemoteImageDisplayable {

    public var imageView: UIImageView {
        return self
    }

    var style: AvatarStyle = .cornerRadius(20) {
        didSet {
            switch style {
            case .circular:
                layer.cornerRadius = min(bounds.width, bounds.height) / 2
            case .cornerRadius(let radius):
                layer.cornerRadius = radius
            }
        }
    }

    public weak var imageDownloadTask: (any Cancellable)?

    public required init(style: AvatarStyle) {
        super.init(frame: .zero)
        self.style = style
        self.contentMode = .scaleToFill
        self.clipsToBounds = true
        self.layer.masksToBounds = true
    }
    
    @MainActor required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override open var intrinsicContentSize: CGSize {
        image?.size ?? super.intrinsicContentSize
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        if case .circular = style {
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }

    open override func setUpTheme() {
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.masksToBounds = true
    }

    open override func setUp() {
        if case .cornerRadius(let cornerRadius) = style {
            layer.cornerRadius = cornerRadius
        }
    }

    open override func setUpUI() {
    }

    open override func contentDidChanged() {

    }

    public func cancelLoading() {
        cancelImageLoading()
        image = nil
    }
}
