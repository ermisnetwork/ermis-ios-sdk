//
// Copyright 2025 Ermis Inc.
//

/// The view that shows the list of reaction toggles/buttons.
open class ReactionPickerReactionsView: MessageReactionsView {
    override public var reactionItemView: MessageReactionItemView.Type {
        components.reactionPickerReactionItemView
    }
}
