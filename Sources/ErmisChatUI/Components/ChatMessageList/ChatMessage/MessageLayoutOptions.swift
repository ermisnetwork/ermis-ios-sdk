//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A typealias of `Set<MessageLayoutOption>` to make the API similar of an `OptionSet`.
public typealias MessageLayoutOptions = Set<MessageLayoutOption>

extension MessageLayoutOptions: Identifiable {
    /// The id is composed by the raw values of each option joined by "-".
    /// This id is then used to compute the reuse identifier of each message cell.
    public var id: String {
        // Since it is a Set, we need to sort it to make sure the value doesn't change per call.
        map(\.rawValue).sorted().joined(separator: "-")
    }
}

public extension MessageLayoutOptions {
    /// Remove multiple message layout options.
    mutating func remove(_ options: MessageLayoutOptions) {
        self = subtracting(options)
    }

    /// Insert multiple message layout options.
    mutating func insert(_ options: MessageLayoutOptions) {
        options.forEach { self.insert($0) }
    }
}

/// Each message layout option is used to define which views will be part of the message cell.
/// A different combination of layout options will produce a different cell reuse identifier.
public struct MessageLayoutOption: RawRepresentable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public extension MessageLayoutOption {
    /// If set all the content will have trailing alignment (by default, the message sent by the current user is flipped).
    static let flipped: Self = "flipped"

    /// If set the message content will be wrapped into a bubble.
    static let bubble: Self = "bubble"

    /// If set the message bubble will not have a `tail` (rendered by default as a non rounded corner)
    static let continuousBubble: Self = "continuousBubble"

    /// If set the message is first of bubble, the  bubble will  have a `tail` (rendered by default as a tail at bottom)
    static let firstSequenceBubble: Self = "firstSequenceBubble"

    /// If set the message is first of bubble, the  bubble will  have a `tail` (rendered by default as a tail at top)
    static let lastSequenceBubble: Self = "lastSequenceBubble"

    /// If set the message content will have an offset (from the `trailing` edge if `flipped` is set otherwise from `leading`)
    /// equal to the avatar size.
    static let avatarSizePadding: Self = "avatarSizePadding"

    /// If set the message author avatar will be shown.
    static let avatar: Self = "avatar"

    /// If set the message author name will be shown in metadata.
    static let authorName: Self = "authorName"

    /// If set the message text content will be shown.
    static let text: Self = "text"

    /// If set the message quoted by the current message will be shown.
    static let quotedMessage: Self = "quotedMessage"

    /// If set the message thread replies information will be shown.
    static let threadInfo: Self = "threadInfo"

    /// If set the reactions of this message will be shown.
    static let reactions: Self = "reactions"

    /// If set the message timestamp will be shown.
    static let timestamp: Self = "timestamp"

    /// If the show edited message history button will be shown.
    static let showEditedHistory: Self = "showEditedHistory"

    /// If set the error indicator will be shown.
    static let errorIndicator: Self = "errorIndicator"

    /// If set, the indicator saying that the message is visible to the current user only will be shown.
    static let onlyVisibleToYouIndicator: Self = "onlyVisibleToYouIndicator"

    /// If set the delivery status will be shown.
    static let deliveryStatusIndicator: Self = "deliveryStatusIndicator"
    
    /// If set the message will have a forwarded indicator.
    static let forwardedMessageIndicator: Self = "forwardedMessageIndicator"

    /// If set all the content will have centered alignment. By default, the system messages are centered.
    ///
    /// `flipped` and `centered` are mutually exclusive. Only one of these two should be used at a time.
    /// If both are specified in the options, `centered` is prioritized
    static let centered: Self = "centered"

    /// If set the translation label will be shown.
    internal static let translation: Self = "translation"
}
