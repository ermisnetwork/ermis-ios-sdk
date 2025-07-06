//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Protocol for action item.
/// Action items are then showed in `MessageActionsView`.
/// Setup individual item by creating new instance that conforms to this protocol.
public protocol MessageActionItem {
    /// Title of `MessageActionItem`.
    var title: String { get }
    /// Icon of `MessageActionItem`.
    var icon: UIImage { get }
    /// Marks whether `MessageActionItem` is primary.
    /// Based on this property, some UI properties can be made.
    /// Default value is `false`.
    var isPrimary: Bool { get }
    /// Marks whether `MessageActionItem` is destructive.
    /// Based on this property, some UI properties can be made.
    /// Default value is `false`
    var isDestructive: Bool { get }
    /// Action that should be triggered when tapping on `MessageActionItem`.
    var action: (MessageActionItem) -> Void { get }
}

extension MessageActionItem {
    public var isPrimary: Bool { false }
    public var isDestructive: Bool { false }
}

/// Instance of `MessageActionItem` for inline reply.
public struct InlineReplyActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `InlineReplyActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `InlineReplyActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.inlineReply
        self.action = action
        icon = theme.icons.messageActionInlineReply
    }
}

/// Instance of `MessageActionItem` for thread reply.
public struct ThreadReplyActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `ThreadReplyActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `ThreadReplyActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.threadReply
        self.action = action
        icon = theme.icons.messageActionThreadReply
    }
}

/// Instance of `MessageActionItem` for edit message action.
public struct EditActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `EditActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `EditActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.edit
        self.action = action
        icon = theme.icons.messageActionEdit
    }
}

/// Intance of `MessageActionItem` for download action.
public struct DownloadActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `DownloadActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `DownloadActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(title: String? = nil,
                action: @escaping (MessageActionItem) -> Void,
                theme: Theme = .default) {
        self.title = title ?? L10n.Message.Actions.download
        self.action = action
        icon = theme.icons.messageActionDownload
    }
}

/// Instance of `MessageActionItem` for copy message action.
public struct CopyActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `CopyActionItem`
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `CopyActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.copy
        self.action = action
        icon = theme.icons.messageActionCopy
    }
}

/// Instance of `MessageActionItem` for mark a message as unread action.
public struct MarkUnreadActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `MarkUnreadActionItem`
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `MarkUnreadActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.markUnread
        self.action = action
        icon = theme.icons.messageActionMarkUnread
    }
}

/// Instance of `MessageActionItem` for unblocking user.
public struct UnblockUserActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `UnblockUserActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `UnblockUserActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.userUnblock
        self.action = action
        icon = theme.icons.messageActionBlockUser
    }
}

/// Instance of `MessageActionItem` for blocking user.
public struct BlockUserActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `BlockUserActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `BlockUserActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.userBlock
        self.action = action
        icon = theme.icons.messageActionBlockUser
    }
}

/// Instance of `MessageActionItem` for muting user.
public struct MuteUserActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `MuteUserActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `MuteUserActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.userMute
        self.action = action
        icon = theme.icons.messageActionMuteUser
    }
}

/// Instance of `MessageActionItem` for unmuting user.
public struct UnmuteUserActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `UnmuteUserActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `UnmuteUserActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.userUnmute
        self.action = action
        icon = theme.icons.messageActionMuteUser
    }
}

/// Instance of `MessageActionItem` for deleting message action.
public struct DeleteActionItem: MessageActionItem {
    public var title: String
    public var isDestructive: Bool { true }
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `DeleteActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `DeleteActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.delete
        self.action = action
        icon = theme.icons.messageActionDelete
    }
}

/// Instance of `MessageActionItem` for resending message action.
public struct ResendActionItem: MessageActionItem {
    public var title: String
    public var isPrimary: Bool { true }
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `ResendActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `ResendActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.resend
        self.action = action
        icon = theme.icons.messageActionResend
    }
}

/// Instance of `FlagActionItem` for flagging a message action.
public struct FlagActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `FlagActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `FlagActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.flag
        self.action = action
        icon = theme.icons.messageActionFlag
    }
}

/// Instance of `PinActionItem` for pinning a message action.
public struct PinActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `PinActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `PinActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.pin
        self.action = action
        icon = theme.icons.messageActionPin
    }
}

/// Instance of `UnpinActionItem` for pinning a message action.
public struct UnpinActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `UnpinActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `UnpinActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.unpin
        self.action = action
        icon = theme.icons.messageActionUnpin
    }
}

/// Instance of `ForwardActionItem` for forwarding a message action.
public struct ForwardActionItem: MessageActionItem {
    public var title: String
    public let icon: UIImage
    public let action: (MessageActionItem) -> Void

    /// Init of `ForwardActionItem`.
    /// - Parameters:
    ///     - title: The name of the action. Provide a value in case you want to override the default title.
    ///     - action: Action to be triggered when `ForwardActionItem` is tapped.
    ///     - theme: `Theme` that is used to configure UI properties.
    public init(
        title: String? = nil,
        action: @escaping (MessageActionItem) -> Void,
        theme: Theme = .default
    ) {
        self.title = title ?? L10n.Message.Actions.forward
        self.action = action
        icon = theme.icons.messageActionForward
    }
}
