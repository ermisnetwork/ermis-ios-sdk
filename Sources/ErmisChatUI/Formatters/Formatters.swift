//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

public struct Formatters {
    /// A formatter that converts the message to textual representation in the message list.
    public var messageTimestamp: MessageTimestampFormatter = DefaultMessageTimestampFormatter()

    /// A formatter that converts the message to textual representation in the channel list.
    public var channelListMessageTimestamp: MessageTimestampFormatter = ChannelListMessageTimestampFormatter()

    /// A formatter that converts the message date separator to textual representation.
    /// This formatter is used to display the message date between each group of messages
    /// and the top date overlay in the message list.
    public var messageDateSeparator: MessageDateSeparatorFormatter = DefaultMessageDateSeparatorFormatter()

    /// A formatter that converts the time a user was last active to textual representation.
    public var userLastActivity: UserLastActivityFormatter = DefaultUserLastActivityFormatter()

    /// A formatter that converts the video duration to textual representation.
    public var videoDuration: VideoDurationFormatter = DefaultVideoDurationFormatter()

    /// A formatter that converts the progress percentage to textual representation.
    public var uploadingProgress: UploadingProgressFormatter = DefaultUploadingProgressFormatter()

    /// A formatter that generates a name for the given channel.
    public var channelName: ChannelNameFormatter = DefaultChannelNameFormatter()

    /// A formatter used for text Markdown
    public var markdownFormatter: MarkdownFormatter = DefaultMarkdownFormatter()

    /// A formatter that converts an audio playback rate to textual representation.
    public var audioPlaybackRateFormatter: AudioPlaybackRateFormatter = DefaultAudioPlaybackRateFormatter()

    /// A formatter that provides a name for a recording based on its position in a list of recordings.
    public var audioRecordingNameFormatter: AudioRecordingNameFormatter = DefaultAudioRecordingNameFormatter()

    /// A formatter that provides a text message for system message.
    public var systemMessage: SystemMessageFormatter = DefaultSystemMessageFormatter()

    /// A formatter that provides a text message for call message.
    public var signalMessage : SignalMessageFormatter = DefaultSignalMessageFormatter()

    /// A boolean value that determines whether Markdown is active for messages to be formatted.
    public var isMarkdownEnabled = false
}

// MARK: - Formatters + Default

public extension Formatters {
    static var `default`: Formatters = .init()
}
