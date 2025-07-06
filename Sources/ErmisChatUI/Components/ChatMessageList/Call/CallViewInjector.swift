//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol CallViewInjectorDelegate: AnyObject {

}

open class CallViewInjector: CustomCellViewInjector {

    public override var customView: UIView? {
        callView
    }

    open override var fillAllAvailableWidth: Bool {
        return false
    }

    open private(set) lazy var callView = contentView
        .components
        .callView.init()
        .withoutAutoresizingMaskConstraints

    open override func contentViewDidLayout(options: MessageLayoutOptions) {
        contentView.bubbleContentContainer.insertArrangedSubview(callView, at: 0)
    }

    open override func contentViewDidcontentDidChanged() {
        callView.content = .init(chatMessage: contentView.content)
        contentView.bubbleView?.backgroundColor = contentView.theme.colors.incommingBubbleMessageBackground
    }

    open override func contentViewDidPrepareForReuse() {
        callView.content = nil
    }
}

