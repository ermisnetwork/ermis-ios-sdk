// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation


// MARK: - Strings

internal enum L10n {
  /// %d of %d
  internal static func currentSelection(_ p1: Int, _ p2: Int) -> String {
    return L10n.tr("Localizable", "current-selection", p1, p2)
  }
  /// From
  internal static var from: String { L10n.tr("Localizable", "from") }
  /// No preview available
  internal static var noPreviewAvailable: String { L10n.tr("Localizable", "no_preview_available") }
  /// You
  internal static var you: String { L10n.tr("Localizable", "you") }

  internal enum Alert {
    internal enum Actions {
      /// Cancel
      internal static var cancel: String { L10n.tr("Localizable", "alert.actions.cancel") }
      /// Delete
      internal static var delete: String { L10n.tr("Localizable", "alert.actions.delete") }
      /// Flag
      internal static var flag: String { L10n.tr("Localizable", "alert.actions.flag") }
      /// Ok
      internal static var ok: String { L10n.tr("Localizable", "alert.actions.ok") }
      /// Unpin
      internal static var unpin: String { L10n.tr("Localizable", "alert.actions.unpin") }
    }
    internal enum Title {
      /// Error
      internal static var error: String { L10n.tr("Localizable", "alert.title.error") }
      /// Info
      internal static var info: String { L10n.tr("Localizable", "alert.title.info") }
      /// Success
      internal static var success: String { L10n.tr("Localizable", "alert.title.success") }
    }
  }

  internal enum Attachment {
    /// File size exceeds the limit. Maximum allowed: 100MB.
    internal static var maxSizeExceeded: String { L10n.tr("Localizable", "attachment.max-size-exceeded") }
  }

  internal enum Audio {
    internal enum Player {
      /// x%@
      internal static func rate(_ p1: Any) -> String {
        return L10n.tr("Localizable", "audio.player.rate", String(describing: p1))
      }
    }
  }

  internal enum Channe {
    internal enum Invitation {
      /// Not enough tokens!
      internal static var notEnoughTokens: String { L10n.tr("Localizable", "channe.invitation.not-enough-tokens") }
    }
  }

  internal enum Channel {
    internal enum Invitation {
      /// Accept the invite to see all messages of this group
      internal static var accceptRequireMessage: String { L10n.tr("Localizable", "channel.invitation.accceptRequireMessage") }
      /// Accept the invite to see all messages of this conversation
      internal static var directAccceptRequireMessage: String { L10n.tr("Localizable", "channel.invitation.directAccceptRequireMessage") }
      /// Get tokens
      internal static var getTokens: String { L10n.tr("Localizable", "channel.invitation.get-tokens") }
      /// Join group %@
      internal static func joinChannel(_ p1: Any) -> String {
        return L10n.tr("Localizable", "channel.invitation.join-channel", String(describing: p1))
      }
      /// %@ needs to accept your invitation to see the messages you've sent.
      internal static func pendingUserNeedAccept(_ p1: Any) -> String {
        return L10n.tr("Localizable", "channel.invitation.pendingUserNeedAccept", String(describing: p1))
      }
      /// Re-check
      internal static var reCheck: String { L10n.tr("Localizable", "channel.invitation.re-check") }
      /// You need to hold any of tokens:
      internal static var requiredTokenMessage: String { L10n.tr("Localizable", "channel.invitation.required-token-message") }
    }
    internal enum Item {
      /// Audio
      internal static var audio: String { L10n.tr("Localizable", "channel.item.audio") }
      /// No messages
      internal static var emptyMessages: String { L10n.tr("Localizable", "channel.item.empty-messages") }
      /// Photo
      internal static var photo: String { L10n.tr("Localizable", "channel.item.photo") }
      /// Video
      internal static var video: String { L10n.tr("Localizable", "channel.item.video") }
      internal enum Search {
        ///  in %@
        internal static func `in`(_ p1: Any) -> String {
          return L10n.tr("Localizable", "channel.item.search.in", String(describing: p1))
        }
      }
    }
    internal enum Name {
      /// + %@ more
      internal static func andXMore(_ p1: Any) -> String {
        return L10n.tr("Localizable", "channel.name.andXMore", String(describing: p1))
      }
      /// No Group
      internal static var missing: String { L10n.tr("Localizable", "channel.name.missing") }
    }
  }

  internal enum ChannelList {
    /// Search
    internal static var search: String { L10n.tr("Localizable", "channelList.search") }
    internal enum Empty {
      /// START CHAT
      internal static var button: String { L10n.tr("Localizable", "channelList.empty.button") }
      /// Start conversations or bring your friends onboard.
      internal static var subtitle: String { L10n.tr("Localizable", "channelList.empty.subtitle") }
      /// Start chat
      internal static var title: String { L10n.tr("Localizable", "channelList.empty.title") }
    }
    internal enum Error {
      /// Error loading groups
      internal static var message: String { L10n.tr("Localizable", "channelList.error.message") }
    }
    internal enum LastMessage {
      /// Cancel audio call
      internal static var cancelAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.cancel-audio-call") }
      /// Cancel video call
      internal static var cancelVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.cancel-video-call") }
      /// Draft
      internal static var draft: String { L10n.tr("Localizable", "channelList.lastMessage.draft") }
      /// Incoming audio call
      internal static var incomingAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.incoming-audio-call") }
      /// Incoming video call
      internal static var incomingVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.incoming-video-call") }
      /// Missed audio call
      internal static var missedAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.missed-audio-call") }
      /// Missed video call
      internal static var missedVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.missed-video-call") }
      /// Outgoing audio call
      internal static var outgoingAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.outgoing-audio-call") }
      /// Outgoing video call
      internal static var outgoingVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.outgoing-video-call") }
    }
    internal enum OngoingCall {
      /// Tap to return call
      internal static var tapToReturnCall: String { L10n.tr("Localizable", "channelList.ongoing-call.tap-to-return-call") }
    }
    internal enum Preview {
      internal enum Voice {
        /// Voice message
        internal static var recording: String { L10n.tr("Localizable", "channelList.preview.voice.recording") }
      }
    }
    internal enum Search {
      internal enum Empty {
        /// No results for %@
        internal static func subtitle(_ p1: Any) -> String {
          return L10n.tr("Localizable", "channelList.search.empty.subtitle", String(describing: p1))
        }
      }
    }
  }

  internal enum Composer {
    /// Join
    internal static var joinButton: String { L10n.tr("Localizable", "composer.join-button") }
    /// Join group to send message.
    internal static var joinChannelTitle: String { L10n.tr("Localizable", "composer.join-channel-title") }
    internal enum Checkmark {
      /// Also send as direct message
      internal static var directMessageReply: String { L10n.tr("Localizable", "composer.checkmark.direct-message-reply") }
    }
    internal enum Filterwords {
      /// The content you entered contains blocked keywords
      internal static var contentContainBlockedKeywords: String { L10n.tr("Localizable", "composer.filterwords.content-contain-blocked-keywords") }
    }
    internal enum LinksDisabled {
      /// Members in this group are not allowed to send links.
      internal static var subtitle: String { L10n.tr("Localizable", "composer.links-disabled.subtitle") }
      /// Links are disabled
      internal static var title: String { L10n.tr("Localizable", "composer.links-disabled.title") }
    }
    internal enum Menu {
      /// Create Poll
      internal static var createPoll: String { L10n.tr("Localizable", "composer.menu.create-poll") }
      /// Location
      internal static var location: String { L10n.tr("Localizable", "composer.menu.location") }
      /// Share File
      internal static var shareFile: String { L10n.tr("Localizable", "composer.menu.share-file") }
    }
    internal enum Picker {
      /// Camera
      internal static var camera: String { L10n.tr("Localizable", "composer.picker.camera") }
      /// Cancel
      internal static var cancel: String { L10n.tr("Localizable", "composer.picker.cancel") }
      /// File
      internal static var file: String { L10n.tr("Localizable", "composer.picker.file") }
      /// Choose attachment type: 
      internal static var fileTitle: String { L10n.tr("Localizable", "composer.picker.file-title") }
      /// Photo or Video
      internal static var media: String { L10n.tr("Localizable", "composer.picker.media") }
      /// Choose images source: 
      internal static var photoTitle: String { L10n.tr("Localizable", "composer.picker.photo-title") }
    }
    internal enum Placeholder {
      /// Write a message
      internal static var message: String { L10n.tr("Localizable", "composer.placeholder.message") }
      /// You can't send messages in this group
      internal static var messageDisabled: String { L10n.tr("Localizable", "composer.placeholder.messageDisabled") }
      /// Slow mode ON
      internal static var slowMode: String { L10n.tr("Localizable", "composer.placeholder.slowMode") }
    }
    internal enum QuotedMessage {
      /// Photo
      internal static var photo: String { L10n.tr("Localizable", "composer.quoted-message.photo") }
    }
    internal enum Suggestions {
      internal enum Commands {
        /// Instant Commands
        internal static var header: String { L10n.tr("Localizable", "composer.suggestions.commands.header") }
      }
    }
    internal enum Title {
      /// Edit Message
      internal static var edit: String { L10n.tr("Localizable", "composer.title.edit") }
      /// Reply to Message
      internal static var reply: String { L10n.tr("Localizable", "composer.title.reply") }
    }
    internal enum UserBlocked {
      /// You have blocked %@.
      internal static func title(_ p1: Any) -> String {
        return L10n.tr("Localizable", "composer.user-blocked.title", String(describing: p1))
      }
      /// Unblock
      internal static var unblock: String { L10n.tr("Localizable", "composer.user-blocked.unblock") }
    }
  }

  internal enum ContactList {
    internal enum Empty {
      /// No contacts
      internal static var title: String { L10n.tr("Localizable", "contactList.empty.title") }
    }
  }

  internal enum Dates {
    /// last seen %d days ago
    internal static func timeAgoDaysPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-days-plural", p1)
    }
    /// last seen one day ago
    internal static var timeAgoDaysSingular: String { L10n.tr("Localizable", "dates.time-ago-days-singular") }
    /// last seen %d hours ago
    internal static func timeAgoHoursPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-hours-plural", p1)
    }
    /// last seen one hour ago
    internal static var timeAgoHoursSingular: String { L10n.tr("Localizable", "dates.time-ago-hours-singular") }
    /// last seen %d minutes ago
    internal static func timeAgoMinutesPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-minutes-plural", p1)
    }
    /// last seen one minute ago
    internal static var timeAgoMinutesSingular: String { L10n.tr("Localizable", "dates.time-ago-minutes-singular") }
    /// last seen %d months ago
    internal static func timeAgoMonthsPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-months-plural", p1)
    }
    /// last seen one month ago
    internal static var timeAgoMonthsSingular: String { L10n.tr("Localizable", "dates.time-ago-months-singular") }
    /// last seen %d seconds ago
    internal static func timeAgoSecondsPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-seconds-plural", p1)
    }
    /// last seen just one second ago
    internal static var timeAgoSecondsSingular: String { L10n.tr("Localizable", "dates.time-ago-seconds-singular") }
    /// last seen %d weeks ago
    internal static func timeAgoWeeksPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-weeks-plural", p1)
    }
    /// last seen one week ago
    internal static var timeAgoWeeksSingular: String { L10n.tr("Localizable", "dates.time-ago-weeks-singular") }
  }

  internal enum Forward {
    /// Forwarding to
    internal static var title: String { L10n.tr("Localizable", "forward.title") }
    internal enum State {
      /// Resend
      internal static var error: String { L10n.tr("Localizable", "forward.state.error") }
      /// Sent
      internal static var forwarded: String { L10n.tr("Localizable", "forward.state.forwarded") }
      /// Sending
      internal static var forwarding: String { L10n.tr("Localizable", "forward.state.forwarding") }
      /// Send
      internal static var `none`: String { L10n.tr("Localizable", "forward.state.none") }
    }
  }

  internal enum InvitedChannelList {
    internal enum Empty {
      /// No invited.
      internal static var title: String { L10n.tr("Localizable", "invitedChannelList.empty.title") }
    }
  }

  internal enum Message {
    /// Message deleted
    internal static var deletedMessagePlaceholder: String { L10n.tr("Localizable", "message.deleted-message-placeholder") }
    /// Edited
    internal static var edited: String { L10n.tr("Localizable", "message.edited") }
    /// Forwarded from %@
    internal static func forwardedFromOther(_ p1: Any) -> String {
      return L10n.tr("Localizable", "message.forwarded-from-other", String(describing: p1))
    }
    /// Forwarded from you
    internal static var forwardedFromYou: String { L10n.tr("Localizable", "message.forwarded-from-you") }
    /// Only visible to you
    internal static var onlyVisibleToYou: String { L10n.tr("Localizable", "message.only-visible-to-you") }
    /// Translated to %@
    internal static func translatedTo(_ p1: Any) -> String {
      return L10n.tr("Localizable", "message.translatedTo", String(describing: p1))
    }
    /// Unsupported Attachment
    internal static var unsupportedAttachment: String { L10n.tr("Localizable", "message.unsupported-attachment") }
    internal enum Actions {
      /// Copy Message
      internal static var copy: String { L10n.tr("Localizable", "message.actions.copy") }
      /// Delete Message
      internal static var delete: String { L10n.tr("Localizable", "message.actions.delete") }
      /// Download
      internal static var download: String { L10n.tr("Localizable", "message.actions.download") }
      /// Edit Message
      internal static var edit: String { L10n.tr("Localizable", "message.actions.edit") }
      /// Flag Message
      internal static var flag: String { L10n.tr("Localizable", "message.actions.flag") }
      /// Forward
      internal static var forward: String { L10n.tr("Localizable", "message.actions.forward") }
      /// Reply
      internal static var inlineReply: String { L10n.tr("Localizable", "message.actions.inline-reply") }
      /// Mark as unread
      internal static var markUnread: String { L10n.tr("Localizable", "message.actions.mark-unread") }
      /// Pin
      internal static var pin: String { L10n.tr("Localizable", "message.actions.pin") }
      /// Resend
      internal static var resend: String { L10n.tr("Localizable", "message.actions.resend") }
      /// Thread Reply
      internal static var threadReply: String { L10n.tr("Localizable", "message.actions.thread-reply") }
      /// Unpin
      internal static var unpin: String { L10n.tr("Localizable", "message.actions.unpin") }
      /// Block User
      internal static var userBlock: String { L10n.tr("Localizable", "message.actions.user-block") }
      /// Mute User
      internal static var userMute: String { L10n.tr("Localizable", "message.actions.user-mute") }
      /// Unblock User
      internal static var userUnblock: String { L10n.tr("Localizable", "message.actions.user-unblock") }
      /// Unmute User
      internal static var userUnmute: String { L10n.tr("Localizable", "message.actions.user-unmute") }
      internal enum Copy {
        /// Message copied to clipboard.
        internal static var successTitle: String { L10n.tr("Localizable", "message.actions.copy.success-title") }
      }
      internal enum Delete {
        /// Are you sure you want to permanently delete this message?
        internal static var confirmationMessage: String { L10n.tr("Localizable", "message.actions.delete.confirmation-message") }
        /// Delete Message
        internal static var confirmationTitle: String { L10n.tr("Localizable", "message.actions.delete.confirmation-title") }
      }
      internal enum Download {
        /// Download failed. Please try again later.
        internal static var failureTitle: String { L10n.tr("Localizable", "message.actions.download.failure-title") }
        /// Download successful.
        internal static var successTitle: String { L10n.tr("Localizable", "message.actions.download.success-title") }
      }
      internal enum Flag {
        /// Do you want to send a copy of this message to a moderator for further investigation?
        internal static var confirmationMessage: String { L10n.tr("Localizable", "message.actions.flag.confirmation-message") }
        /// Flag Message
        internal static var confirmationTitle: String { L10n.tr("Localizable", "message.actions.flag.confirmation-title") }
      }
      internal enum Forward {
        /// Unable to forward the message. Please try again.
        internal static var failureTitle: String { L10n.tr("Localizable", "message.actions.forward.failure-title") }
        /// Message forwarded successfully.
        internal static var successTitle: String { L10n.tr("Localizable", "message.actions.forward.success-title") }
      }
      internal enum Pin {
        /// Message pinned.
        internal static var successMessage: String { L10n.tr("Localizable", "message.actions.pin.success-message") }
        /// Unable to pin the message. Please try again.
        internal static var unsuccessMessage: String { L10n.tr("Localizable", "message.actions.pin.unsuccess-message") }
      }
      internal enum Unpin {
        /// Are you sure you want to unpin this message? It will no longer appear at the top of the conversation.
        internal static var confirmationMessage: String { L10n.tr("Localizable", "message.actions.unpin.confirmation-message") }
        /// Unpin this message?
        internal static var confirmationTitle: String { L10n.tr("Localizable", "message.actions.unpin.confirmation-title") }
        /// Message unpinned.
        internal static var successMessage: String { L10n.tr("Localizable", "message.actions.unpin.success-message") }
        /// Unable to unpin the message. Please try again.
        internal static var unsuccessMessage: String { L10n.tr("Localizable", "message.actions.unpin.unsuccess-message") }
      }
    }
    internal enum Call {
      /// You cancel audio call
      internal static var audioCanceledByMe: String { L10n.tr("Localizable", "message.call.audio-canceled-by-me") }
      /// You rejected audio call
      internal static var audioRejectedByMe: String { L10n.tr("Localizable", "message.call.audio-rejected-by-me") }
      /// Receiver rejected audio call
      internal static var audioRejectedByReceiver: String { L10n.tr("Localizable", "message.call.audio-rejected-by-receiver") }
      /// Incoming audio call
      internal static var incomingAudioCall: String { L10n.tr("Localizable", "message.call.incoming-audio-call") }
      /// Incoming video call
      internal static var incomingVideoCall: String { L10n.tr("Localizable", "message.call.incoming-video-call") }
      /// You missed audio call
      internal static var missedAudioCall: String { L10n.tr("Localizable", "message.call.missed-audio-call") }
      /// You missed video call
      internal static var missedVideoCall: String { L10n.tr("Localizable", "message.call.missed-video-call") }
      /// Outgoing audio call
      internal static var outgoingAudioCall: String { L10n.tr("Localizable", "message.call.outgoing-audio-call") }
      /// Outgoing video call
      internal static var outgoingVideoCall: String { L10n.tr("Localizable", "message.call.outgoing-video-call") }
      /// Receiver was busy
      internal static var receiverBusy: String { L10n.tr("Localizable", "message.call.receiver-busy") }
      /// You cancel video call
      internal static var videoCanceledByMe: String { L10n.tr("Localizable", "message.call.video-canceled-by-me") }
      /// You rejected video call
      internal static var videoRejectedByMe: String { L10n.tr("Localizable", "message.call.video-rejected-by-me") }
      /// Receiver rejected video call
      internal static var videoRejectedByReceiver: String { L10n.tr("Localizable", "message.call.video-rejected-by-receiver") }
    }
    internal enum Moderation {
      /// Delete Message
      internal static var delete: String { L10n.tr("Localizable", "message.moderation.delete") }
      /// Edit Message
      internal static var edit: String { L10n.tr("Localizable", "message.moderation.edit") }
      /// Consider how your comment might make others feel and be sure to follow our Community Guidelines.
      internal static var message: String { L10n.tr("Localizable", "message.moderation.message") }
      /// Send Anyway
      internal static var resend: String { L10n.tr("Localizable", "message.moderation.resend") }
      /// Are you sure?
      internal static var title: String { L10n.tr("Localizable", "message.moderation.title") }
    }
    internal enum Sending {
      /// UPLOADING FAILED
      internal static var attachmentUploadingFailed: String { L10n.tr("Localizable", "message.sending.attachment-uploading-failed") }
    }
    internal enum System {
      /// Cooldown feature enabled by Group Admin. Cooldown duration set to %@
      internal static func adjustCooldown(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.adjust-cooldown", String(describing: p1))
      }
      /// %@ changed the group description
      internal static func channelDesciptionUpdated(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.channel-desciption-updated", String(describing: p1))
      }
      /// %@ changed the group avatar
      internal static func channelImageUpdated(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.channel-image-updated", String(describing: p1))
      }
      /// %@ changed the group name to "%@"
      internal static func channelNameUpdated(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "message.system.channel-name-updated", String(describing: p1), String(describing: p2))
      }
      /// %@ update group filter words
      internal static func filterWordsChanged(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.filter-words-changed", String(describing: p1))
      }
      /// %@ banned from interacting in this group by Group Admin
      internal static func memberBanned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-banned", String(describing: p1))
      }
      /// %@ removed as the moderator from this group
      internal static func memberDemoted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-demoted", String(describing: p1))
      }
      /// %@ joined this group
      internal static func memberJoinedChannel(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-joined-channel", String(describing: p1))
      }
      /// %@ joined this conversation
      internal static func memberJoinedConversation(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-joined-conversation", String(describing: p1))
      }
      /// %@ left this group
      internal static func memberLeave(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-leave", String(describing: p1))
      }
      /// %@ assigned as the moderator for this group
      internal static func memberPromoted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-promoted", String(describing: p1))
      }
      /// %@ removed from this group
      internal static func memberRemoved(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-removed", String(describing: p1))
      }
      /// %@ unbanned and now can interact in this group
      internal static func memberUnbanned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-unbanned", String(describing: p1))
      }
      /// A message has been forwarded
      internal static var messageForwarded: String { L10n.tr("Localizable", "message.system.message-forwarded") }
      /// %@ pinned a message
      internal static func messagePinned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.message-pinned", String(describing: p1))
      }
      /// %@ unpinned a message
      internal static func messageUnpinned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.message-unpinned", String(describing: p1))
      }
      /// %@ updated member permission of group
      internal static func otherUpdatedMemberPermission(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.other-updated-member-permission", String(describing: p1))
      }
      /// Member %@ made this group private
      internal static func setChannelPrivate(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.set-channel-private", String(describing: p1))
      }
      /// Member %@ made this group public
      internal static func setChannelPublic(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.set-channel-public", String(describing: p1))
      }
      /// Cooldown has been disabled
      internal static var turnOffCooldown: String { L10n.tr("Localizable", "message.system.turn-off-cooldown") }
      /// Cooldown feature enabled by Group Admin. Cooldown duration set to %@
      internal static func turnOnCooldown(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.turn-on-cooldown", String(describing: p1))
      }
      /// %@ declined to join this group
      internal static func userRejectedInvitation(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.user-rejected-invitation", String(describing: p1))
      }
      /// You banned from interacting in this group by Group Admin
      internal static var youBanned: String { L10n.tr("Localizable", "message.system.you-banned") }
      /// You removed as the moderator from this group
      internal static var youDemoted: String { L10n.tr("Localizable", "message.system.you-demoted") }
      /// You joined this group
      internal static var youJoinedChannel: String { L10n.tr("Localizable", "message.system.you-joined-channel") }
      /// You joined this conversation
      internal static var youJoinedConversation: String { L10n.tr("Localizable", "message.system.you-joined-conversation") }
      /// You left this group
      internal static var youLeave: String { L10n.tr("Localizable", "message.system.you-leave") }
      /// You assigned as the moderator for this group
      internal static var youPromoted: String { L10n.tr("Localizable", "message.system.you-promoted") }
      /// You made this group private
      internal static var youSetChannelPrivate: String { L10n.tr("Localizable", "message.system.you-set-channel-private") }
      /// You made this group public
      internal static var youSetChannelPublic: String { L10n.tr("Localizable", "message.system.you-set-channel-public") }
      /// You unbanned and now can interact in this group
      internal static var youUnbanned: String { L10n.tr("Localizable", "message.system.you-unbanned") }
      /// You updated member permission of group
      internal static var youUpdatedMemberPermission: String { L10n.tr("Localizable", "message.system.you-updated-member-permission") }
      /// You have forwarded a message
      internal static var yourMessageForwarded: String { L10n.tr("Localizable", "message.system.your-message-forwarded") }
    }
    internal enum Thread {
      internal enum Replies {
        /// Plural format key: "%#@replies@"
        internal static func count(_ p1: Int) -> String {
          return L10n.tr("Localizable", "message.thread.replies.count", p1)
        }
      }
    }
    internal enum Threads {
      /// Plural format key: "%#@replies@"
      internal static func count(_ p1: Int) -> String {
        return L10n.tr("Localizable", "message.threads.count", p1)
      }
      /// Thread Reply
      internal static var reply: String { L10n.tr("Localizable", "message.threads.reply") }
      /// with %@
      internal static func replyWith(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.threads.replyWith", String(describing: p1))
      }
    }
    internal enum Title {
      /// %d members
      internal static func group(_ p1: Int) -> String {
        return L10n.tr("Localizable", "message.title.group", p1)
      }
      /// Offline
      internal static var offline: String { L10n.tr("Localizable", "message.title.offline") }
      /// Online
      internal static var online: String { L10n.tr("Localizable", "message.title.online") }
    }
    internal enum Unread {
      /// Plural format key: "%#@unread@"
      internal static func count(_ p1: Int) -> String {
        return L10n.tr("Localizable", "message.unread.count", p1)
      }
    }
  }

  internal enum MessageList {
    /// Plural format key: "%#@unreads@"
    internal static func jumpToUnreadButton(_ p1: Int) -> String {
      return L10n.tr("Localizable", "messageList.jump-to-unread-button", p1)
    }
    internal enum TypingIndicator {
      /// Someone is typing
      internal static var typingUnknown: String { L10n.tr("Localizable", "messageList.typingIndicator.typing-unknown") }
      /// Plural format key: "%1$@%2$#@typing@"
      internal static func users(_ p1: Any, _ p2: Int) -> String {
        return L10n.tr("Localizable", "messageList.typingIndicator.users", String(describing: p1), p2)
      }
    }
  }

  internal enum Pin {
    internal enum Collapsed {
      /// Pinned messages
      internal static var title: String { L10n.tr("Localizable", "pin.collapsed.title") }
    }
  }

  internal enum Reaction {
    internal enum Authors {
      /// Plural format key: "%#@reactions@"
      internal static func numberOfReactions(_ p1: Int) -> String {
        return L10n.tr("Localizable", "reaction.authors.number-of-reactions", p1)
      }
    }
  }

  internal enum Recording {
    /// Slide to cancel
    internal static var slideToCancel: String { L10n.tr("Localizable", "recording.slideToCancel") }
    /// Hold to record, release to send
    internal static var tip: String { L10n.tr("Localizable", "recording.tip") }
    internal enum Presentation {
      /// Plural format key: "%#@recording@"
      internal static func name(_ p1: Int) -> String {
        return L10n.tr("Localizable", "recording.presentation.name", p1)
      }
    }
  }
}

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg...) -> String {
     // TODO: Using using Theme.default prohibits using Theme injection
     let format = Theme.default.localizationProvider(key, table)
     return String(format: format, locale: Locale.current, arguments: args)
  }
}

private final class BundleToken {
  static let bundle: Bundle = .ermisChatUI
}

