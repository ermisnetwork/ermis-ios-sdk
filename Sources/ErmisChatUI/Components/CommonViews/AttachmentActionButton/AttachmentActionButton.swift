//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Button used to take an action on attachment being uploaded.
open class AttachmentActionButton: _Button, ThemeProvider {
    /// The content saying which action the button represents
    public enum Content {
        case uploaded
        case restart
        case cancel
    }

    /// The content this button displays
    open var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    /// The button size. It's 24x24 by default
    open var size: CGSize {
        .init(width: 24, height: 24)
    }

    override open func setUpUI() {
        super.setUpUI()

        contentEdgeInsets = .init(top: 6, left: 6, bottom: 6, right: 6)
        pin(anchors: [.width], to: size.width)
        pin(anchors: [.height], to: size.height)
    }

    override open func setUpTheme() {
        super.setUpTheme()

        imageView?.contentMode = .scaleAspectFit
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        backgroundColor = content.map { _ in
            theme.colors.surfaceContainerHighest
        }

        let image: UIImage? = content.flatMap {
            switch $0 {
            case .uploaded:
                return theme.icons.whiteCheckmark.tinted(with: theme.colors.inverseOnSurface)
            case .restart:
                return theme.icons.restart.tinted(with: theme.colors.inverseOnSurface)
            case .cancel:
                return theme.icons.close.tinted(with: theme.colors.inverseOnSurface)
            }
        }
        setImage(image, for: .normal)
    }
}
