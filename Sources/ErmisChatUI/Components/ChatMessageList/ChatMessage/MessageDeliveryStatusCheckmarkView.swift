//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays message delivery receipts.
open class MessageDeliveryStatusCheckmarkView: _View, UIProvider {
    /// The content shown by the view.
    public struct Content {
        public var deliveryStatus: MessageDeliveryStatus
    }

    /// The data this view component shows.
    open var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    /// The image view showing read state of the message.
    open private(set) lazy var imageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    override open func setUpTheme() {
        super.setUpTheme()

        imageView.contentMode = .scaleAspectFit
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(imageView)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        imageView.image = content.flatMap {
            switch $0.deliveryStatus {
            case .pending:
                return theme.icons.messageDeliveryStatusSending
            case .sent:
                return theme.icons.messageDeliveryStatusSent
            case .read:
                return theme.icons.messageDeliveryStatusRead
            case .failed:
                return theme.icons.messageDeliveryStatusFailed
            default:
                return nil
            }
        }

        imageView.tintColor = content.map {
            switch $0.deliveryStatus {
            case .read:
                return theme.colors.primary
            case .failed:
                return theme.colors.error
            default:
                return theme.colors.subTitleTextLow
            }
        }

        imageView.accessibilityIdentifier = imageViewAccessibilityIdentifier
    }

    // MARK: - Private

    private var imageViewAccessibilityIdentifier: String {
        let prefix = "imageView"

        guard let status = content?.deliveryStatus else {
            return prefix
        }

        return "\(prefix)_\(status.rawValue)"
    }
}
