//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

open class ToastView: _View, ThemeProvider {

    open private(set) lazy var mainStackView = createMainStackView()
    open private(set)  lazy var titleStackView = createTitleStackView()

    open private(set)  lazy var imageView = createImageView()
    open private(set)  lazy var titleLabel: UILabel = createTitleLabel()
    open private(set)  lazy var messageLabel: UILabel = createMessageLabel()

    private var titleLabelLeadingConstraint : NSLayoutConstraint?

    var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    var hasTitle: Bool { content?.title.isEmptyOrNil == false }
    var hasMessage: Bool { content?.message.isEmptyOrNil == false }

    // MARK: - Init
    required public init() {
        super.init(frame: .zero)
    }

    @MainActor required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    // MARK: - Setup
    open override func setUp() {
        layer.masksToBounds = true
        layer.cornerRadius = 8
    }

    open override func setUpUI() {
        addSubviews([mainStackView])
        mainStackView.pin(anchors: [.centerX, .centerY], to: self)
        mainStackView.pin(anchors: [.top, .leading], to: self, contant: 12)

        imageView.pin(anchors: [.width, .height], to: 24)
    }

    open override func setUpTheme() {
        backgroundColor = content?.style.backgroundColor
        imageView.tintColor = content?.style.imageTintColor
        titleLabel.textColor = content?.style.textColor
        titleLabel.font = theme.fonts.body
        messageLabel.textColor = content?.style.textColor
        messageLabel.font = theme.fonts.footnote
    }

    open override func contentDidChanged() {
        imageView.image = content?.style.icon
        imageView.isHidden = !(content?.showIcon ?? false)
        titleLabel.text = content?.title
        titleLabel.isHidden = !hasTitle
        messageLabel.text = content?.message
        messageLabel.isHidden = !hasMessage
    }
}
// MARK: - Create UI
extension ToastView {
    private func createMainStackView() -> ContainerStackView {
        let stackView = ContainerStackView(
            axis: .horizontal,
            alignment: .center,
            spacing: 8,
            distribution: .natural,
            arrangedSubviews: [
                imageView, titleStackView
            ]
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }

    private func createTitleStackView() -> ContainerStackView {
        let stackView = ContainerStackView(
            axis: .vertical,
            alignment: .fill,
            spacing: 4,
            distribution: .natural,
            arrangedSubviews: [titleLabel, messageLabel]
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }

    private func createImageView() -> UIImageView {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }

    private func createTitleLabel() -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .left
        label.backgroundColor = .clear
        label.font = theme.fonts.body.bold
        label.textColor = theme.colors.text
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func createMessageLabel() -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .left
        label.backgroundColor = .clear
        label.font = theme.fonts.body
        label.textColor = theme.colors.text
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
// MARK: - Content
extension ToastView {
    struct Content {
        let showIcon: Bool
        let title: String?
        let message: String?
        let style: ToastStyle
    }
}

public enum ToastStyle {
    case neutral
    case info
    case success
    case error
    case custom(backgroundColor: UIColor,
                textColor: UIColor,
                icon: UIImage?,
                imageTintColor: UIColor)


    public var backgroundColor: UIColor {
        let theme = Theme.default
        switch self {
        case .neutral:
            return theme.colors.surfaceContainerLow
        case .info:
            return theme.colors.infoContainer
        case .success:
            return theme.colors.successContainer
        case .error:
            return theme.colors.errorContainer
        case .custom(let backgroundColor, _, _, _):
            return backgroundColor
        }
    }

    public var textColor: UIColor {
        let theme = Theme.default
        switch self {
        case .neutral:
            return theme.colors.onSurface
        case .info:
            return theme.colors.onInfoContainer
        case .success:
            return theme.colors.onSuccessContainer
        case .error:
            return theme.colors.onErrorContainer
        case .custom(_, let textColor, _, _):
            return textColor
        }
    }

    var icon: UIImage? {
        let theme = Theme.default
        switch self {
        case .success:
            return theme.icons.check
        case .custom(_, _, let icon, _):
            return icon
        default:
            return theme.icons.info
        }
    }

    var imageTintColor: UIColor {
        let theme = Theme.default
        switch self {
        case .neutral:
            return theme.colors.onSurface
        case .info:
            return theme.colors.info
        case .success:
            return theme.colors.success
        case .error:
            return theme.colors.error
        case .custom(_, _, _, let imageTintColor):
            return imageTintColor
        }
    }
}
