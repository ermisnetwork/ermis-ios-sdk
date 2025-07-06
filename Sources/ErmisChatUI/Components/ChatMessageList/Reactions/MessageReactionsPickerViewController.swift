//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Controller for the message reactions picker as a list of toggles.
open class MessageReactionsPickerViewController: _ViewController, UIProvider, MessageControllerDelegate {
    public var messageController: MessageController!

    // MARK: - Subviews

    public private(set) lazy var reactionsBubble = components
        .reactionPickerBubbleView
        .init()
        .withoutAutoresizingMaskConstraints

    // MARK: - Life Cycle

    override open func setUp() {
        super.setUp()
        messageController.delegate = self
    }

    override open func setUpUI() {
        view.embed(reactionsBubble)
    }

    override open func contentDidChanged() {
        reactionsBubble.content = messageController.message.map { message in
            let userReactionIDs = Set(message.currentUserReactions.map(\.type))

            return .init(
                style: message.isSentByCurrentUser ? .bigOutgoing : .bigIncoming,
                reactions: theme.icons.availableReactions
                    .map { return ($0, $1)}
                    .sorted(by: { $0.1.positionValue < $1.1.positionValue})
                    .map {
                        .init(
                            type: $0.0,
                            score: message.reactionScores[$0.0] ?? 0,
                            isChosenByCurrentUser: userReactionIDs.contains($0.0)
                        )
                    },
                didTapOnReaction: { [weak self] in
                    self?.toggleReaction($0)
                }
            )
        }
    }

    // MARK: - Actions

    // toggleReaction toggles on/off the reaction for the message
    open func toggleReaction(_ reaction: MessageReactionType) {
        guard let message = messageController.message else { return }

        let completion: (Error?) -> Void = { [weak self] _ in
            self?.dismiss(animated: true)
        }

        let shouldRemove = message.currentUserReactions.contains { $0.type == reaction }
        shouldRemove
            ? messageController.deleteReaction(reaction, completion: completion)
            : messageController.addReaction(reaction, completion: completion)
    }

    // MARK: - MessageControllerDelegate

    open func messageController(
        _ controller: MessageController,
        didChangeMessage change: EntityChange<ChatMessage>
    ) {
        switch change {
        case .create, .remove: break
        case .update: updateContentIfNeeded()
        }
    }
}
