//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import ErmisSharedUI
import UIKit

/// An object used for injecting custom content views into `MessageContentView`. The injector is also
/// responsible for updating the content of the injected views.
///
/// - Important: This is an abstract superclass meant to be subclassed.
///
open class CustomCellViewInjector: CustomCellViewInjectorProtocol {
    /// A customView will be add to `bubbleContentContainer`
    public var customView: UIView? {
        return nil
    }

    /// Says whether a message content should start filling all available width.
    /// Is `true` by default.
    open var fillAllAvailableWidth: Bool {
        return true
    }

    /// The target view used for injecting the views of this injector.
    public unowned let contentView: MessageContentView

    /// Creates a new instance of the injector.
    ///
    /// - Parameter contentView: The target view used for injecting the views of this injector.
    ///
    public required init(_ contentView: MessageContentView) {
        self.contentView = contentView
    }

    /// Called after `contentView.prepareForReuse` is called.
    open func contentViewDidPrepareForReuse() {}

    /// Called after `contentView.updateContent` is called.
    open func contentViewDidcontentDidChanged() {}

    open func contentViewDidLayout(options: MessageLayoutOptions) {
        guard let customView else { return }
        if customView.superview != nil {
            customView.removeFromSuperview()
        }
        contentView.bubbleContentContainer.insertArrangedSubview(customView,
                                                                 at: 0,
                                                                 respectsLayoutMargins: false)
    }
}

extension CustomCellViewInjector {
    // Helper method to get attachments of message.
    public func attachments<Payload: AttachmentPayload>(
        payloadType: Payload.Type
    ) -> [MessageAttachment<Payload>] {
        contentView.content?.attachments(payloadType: payloadType) ?? []
    }
}
