// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation


// MARK: - Strings

public enum L10n {
  /// %d of %d
  public static func currentSelection(_ p1: Int, _ p2: Int) -> String {
    return L10n.tr("Localizable", "current-selection", p1, p2)
  }
  /// From
  public static var from: String { L10n.tr("Localizable", "from") }
  /// No preview available
  public static var noPreviewAvailable: String { L10n.tr("Localizable", "no_preview_available") }
  /// You
  public static var you: String { L10n.tr("Localizable", "you") }

  public enum Alert {
    public enum Actions {
      /// Cancel
      public static var cancel: String { L10n.tr("Localizable", "alert.actions.cancel") }
      /// Delete
      public static var delete: String { L10n.tr("Localizable", "alert.actions.delete") }
      /// Flag
      public static var flag: String { L10n.tr("Localizable", "alert.actions.flag") }
      /// Ok
      public static var ok: String { L10n.tr("Localizable", "alert.actions.ok") }
      /// Unpin
      public static var unpin: String { L10n.tr("Localizable", "alert.actions.unpin") }
    }
    public enum Title {
      /// Error
      public static var error: String { L10n.tr("Localizable", "alert.title.error") }
      /// Info
      public static var info: String { L10n.tr("Localizable", "alert.title.info") }
      /// Success
      public static var success: String { L10n.tr("Localizable", "alert.title.success") }
    }
  }

  public enum Attachment {
    /// File size exceeds the limit. Maximum allowed: 100MB.
    public static var maxSizeExceeded: String { L10n.tr("Localizable", "attachment.max-size-exceeded") }
  }

  public enum Audio {
    public enum Player {
      /// x%@
      public static func rate(_ p1: Any) -> String {
        return L10n.tr("Localizable", "audio.player.rate", String(describing: p1))
      }
    }
  }

  public enum Channe {
    public enum Invitation {
      /// Not enough tokens!
      public static var notEnoughTokens: String { L10n.tr("Localizable", "channe.invitation.not-enough-tokens") }
    }
  }

  public enum Channel {
    public enum Invitation {
      /// Accept the invite to see all messages of this group
      public static var accceptRequireMessage: String { L10n.tr("Localizable", "channel.invitation.accceptRequireMessage") }
      /// Accept the invite to see all messages of this conversation
      public static var directAccceptRequireMessage: String { L10n.tr("Localizable", "channel.invitation.directAccceptRequireMessage") }
      /// Get tokens
      public static var getTokens: String { L10n.tr("Localizable", "channel.invitation.get-tokens") }
      /// Join group %@
      public static func joinChannel(_ p1: Any) -> String {
        return L10n.tr("Localizable", "channel.invitation.join-channel", String(describing: p1))
      }
      /// %@ needs to accept your invitation to see the messages you've sent.
      public static func pendingUserNeedAccept(_ p1: Any) -> String {
        return L10n.tr("Localizable", "channel.invitation.pendingUserNeedAccept", String(describing: p1))
      }
      /// Re-check
      public static var reCheck: String { L10n.tr("Localizable", "channel.invitation.re-check") }
      /// You need to hold any of tokens:
      public static var requiredTokenMessage: String { L10n.tr("Localizable", "channel.invitation.required-token-message") }
    }
    public enum Item {
      /// Audio
      public static var audio: String { L10n.tr("Localizable", "channel.item.audio") }
      /// No messages
      public static var emptyMessages: String { L10n.tr("Localizable", "channel.item.empty-messages") }
      /// Photo
      public static var photo: String { L10n.tr("Localizable", "channel.item.photo") }
      /// Video
      public static var video: String { L10n.tr("Localizable", "channel.item.video") }
      public enum Search {
        ///  in %@
        public static func `in`(_ p1: Any) -> String {
          return L10n.tr("Localizable", "channel.item.search.in", String(describing: p1))
        }
      }
    }
    public enum Name {
      /// + %@ more
      public static func andXMore(_ p1: Any) -> String {
        return L10n.tr("Localizable", "channel.name.andXMore", String(describing: p1))
      }
      /// No Group
      public static var missing: String { L10n.tr("Localizable", "channel.name.missing") }
    }
  }

  public enum ChannelList {
    /// Search
    public static var search: String { L10n.tr("Localizable", "channelList.search") }
    public enum Empty {
      /// START CHAT
      public static var button: String { L10n.tr("Localizable", "channelList.empty.button") }
      /// Start conversations or bring your friends onboard.
      public static var subtitle: String { L10n.tr("Localizable", "channelList.empty.subtitle") }
      /// Start chat
      public static var title: String { L10n.tr("Localizable", "channelList.empty.title") }
    }
    public enum Error {
      /// Error loading groups
      public static var message: String { L10n.tr("Localizable", "channelList.error.message") }
    }
    public enum LastMessage {
      /// Cancel audio call
      public static var cancelAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.cancel-audio-call") }
      /// Cancel video call
      public static var cancelVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.cancel-video-call") }
      /// Draft
      public static var draft: String { L10n.tr("Localizable", "channelList.lastMessage.draft") }
      /// Incoming audio call
      public static var incomingAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.incoming-audio-call") }
      /// Incoming video call
      public static var incomingVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.incoming-video-call") }
      /// Missed audio call
      public static var missedAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.missed-audio-call") }
      /// Missed video call
      public static var missedVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.missed-video-call") }
      /// Outgoing audio call
      public static var outgoingAudioCall: String { L10n.tr("Localizable", "channelList.lastMessage.outgoing-audio-call") }
      /// Outgoing video call
      public static var outgoingVideoCall: String { L10n.tr("Localizable", "channelList.lastMessage.outgoing-video-call") }
    }
    public enum OngoingCall {
      /// Tap to return call
      public static var tapToReturnCall: String { L10n.tr("Localizable", "channelList.ongoing-call.tap-to-return-call") }
    }
    public enum Preview {
      public enum Voice {
        /// Voice message
        public static var recording: String { L10n.tr("Localizable", "channelList.preview.voice.recording") }
      }
    }
    public enum Search {
      public enum Empty {
        /// No results for %@
        public static func subtitle(_ p1: Any) -> String {
          return L10n.tr("Localizable", "channelList.search.empty.subtitle", String(describing: p1))
        }
      }
    }
  }

  public enum Composer {
    /// Join
    public static var joinButton: String { L10n.tr("Localizable", "composer.join-button") }
    /// Join group to send message.
    public static var joinChannelTitle: String { L10n.tr("Localizable", "composer.join-channel-title") }
    public enum Checkmark {
      /// Also send as direct message
      public static var directMessageReply: String { L10n.tr("Localizable", "composer.checkmark.direct-message-reply") }
    }
    public enum Filterwords {
      /// The content you entered contains blocked keywords
      public static var contentContainBlockedKeywords: String { L10n.tr("Localizable", "composer.filterwords.content-contain-blocked-keywords") }
    }
    public enum LinksDisabled {
      /// Members in this group are not allowed to send links.
      public static var subtitle: String { L10n.tr("Localizable", "composer.links-disabled.subtitle") }
      /// Links are disabled
      public static var title: String { L10n.tr("Localizable", "composer.links-disabled.title") }
    }
    public enum Menu {
      /// Create Poll
      public static var createPoll: String { L10n.tr("Localizable", "composer.menu.create-poll") }
      /// Location
      public static var location: String { L10n.tr("Localizable", "composer.menu.location") }
      /// Share File
      public static var shareFile: String { L10n.tr("Localizable", "composer.menu.share-file") }
    }
    public enum Picker {
      /// Camera
      public static var camera: String { L10n.tr("Localizable", "composer.picker.camera") }
      /// Cancel
      public static var cancel: String { L10n.tr("Localizable", "composer.picker.cancel") }
      /// File
      public static var file: String { L10n.tr("Localizable", "composer.picker.file") }
      /// Choose attachment type: 
      public static var fileTitle: String { L10n.tr("Localizable", "composer.picker.file-title") }
      /// Photo or Video
      public static var media: String { L10n.tr("Localizable", "composer.picker.media") }
      /// Choose images source: 
      public static var photoTitle: String { L10n.tr("Localizable", "composer.picker.photo-title") }
    }
    public enum Placeholder {
      /// Write a message
      public static var message: String { L10n.tr("Localizable", "composer.placeholder.message") }
      /// You can't send messages in this group
      public static var messageDisabled: String { L10n.tr("Localizable", "composer.placeholder.messageDisabled") }
      /// Slow mode ON
      public static var slowMode: String { L10n.tr("Localizable", "composer.placeholder.slowMode") }
    }
    public enum QuotedMessage {
      /// Photo
      public static var photo: String { L10n.tr("Localizable", "composer.quoted-message.photo") }
    }
    public enum Suggestions {
      public enum Commands {
        /// Instant Commands
        public static var header: String { L10n.tr("Localizable", "composer.suggestions.commands.header") }
      }
    }
    public enum Title {
      /// Edit Message
      public static var edit: String { L10n.tr("Localizable", "composer.title.edit") }
      /// Reply to Message
      public static var reply: String { L10n.tr("Localizable", "composer.title.reply") }
    }
    public enum UserBlocked {
      /// You have blocked %@.
      public static func title(_ p1: Any) -> String {
        return L10n.tr("Localizable", "composer.user-blocked.title", String(describing: p1))
      }
      /// Unblock
      public static var unblock: String { L10n.tr("Localizable", "composer.user-blocked.unblock") }
    }
  }

  public enum ContactList {
    public enum Empty {
      /// No contacts
      public static var title: String { L10n.tr("Localizable", "contactList.empty.title") }
    }
  }

  public enum Dates {
    /// last seen %d days ago
    public static func timeAgoDaysPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-days-plural", p1)
    }
    /// last seen one day ago
    public static var timeAgoDaysSingular: String { L10n.tr("Localizable", "dates.time-ago-days-singular") }
    /// last seen %d hours ago
    public static func timeAgoHoursPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-hours-plural", p1)
    }
    /// last seen one hour ago
    public static var timeAgoHoursSingular: String { L10n.tr("Localizable", "dates.time-ago-hours-singular") }
    /// last seen %d minutes ago
    public static func timeAgoMinutesPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-minutes-plural", p1)
    }
    /// last seen one minute ago
    public static var timeAgoMinutesSingular: String { L10n.tr("Localizable", "dates.time-ago-minutes-singular") }
    /// last seen %d months ago
    public static func timeAgoMonthsPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-months-plural", p1)
    }
    /// last seen one month ago
    public static var timeAgoMonthsSingular: String { L10n.tr("Localizable", "dates.time-ago-months-singular") }
    /// last seen %d seconds ago
    public static func timeAgoSecondsPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-seconds-plural", p1)
    }
    /// last seen just one second ago
    public static var timeAgoSecondsSingular: String { L10n.tr("Localizable", "dates.time-ago-seconds-singular") }
    /// last seen %d weeks ago
    public static func timeAgoWeeksPlural(_ p1: Int) -> String {
      return L10n.tr("Localizable", "dates.time-ago-weeks-plural", p1)
    }
    /// last seen one week ago
    public static var timeAgoWeeksSingular: String { L10n.tr("Localizable", "dates.time-ago-weeks-singular") }
  }

  public enum Forward {
    /// Forwarding to
    public static var title: String { L10n.tr("Localizable", "forward.title") }
    public enum State {
      /// Resend
      public static var error: String { L10n.tr("Localizable", "forward.state.error") }
      /// Sent
      public static var forwarded: String { L10n.tr("Localizable", "forward.state.forwarded") }
      /// Sending
      public static var forwarding: String { L10n.tr("Localizable", "forward.state.forwarding") }
      /// Send
      public static var `none`: String { L10n.tr("Localizable", "forward.state.none") }
    }
  }

  public enum InvitedChannelList {
    public enum Empty {
      /// No invited.
      public static var title: String { L10n.tr("Localizable", "invitedChannelList.empty.title") }
    }
  }

  public enum Message {
    /// Message deleted
    public static var deletedMessagePlaceholder: String { L10n.tr("Localizable", "message.deleted-message-placeholder") }
    /// Edited
    public static var edited: String { L10n.tr("Localizable", "message.edited") }
    /// Forwarded from %@
    public static func forwardedFromOther(_ p1: Any) -> String {
      return L10n.tr("Localizable", "message.forwarded-from-other", String(describing: p1))
    }
    /// Forwarded from you
    public static var forwardedFromYou: String { L10n.tr("Localizable", "message.forwarded-from-you") }
    /// Only visible to you
    public static var onlyVisibleToYou: String { L10n.tr("Localizable", "message.only-visible-to-you") }
    /// Translated to %@
    public static func translatedTo(_ p1: Any) -> String {
      return L10n.tr("Localizable", "message.translatedTo", String(describing: p1))
    }
    /// Unsupported Attachment
    public static var unsupportedAttachment: String { L10n.tr("Localizable", "message.unsupported-attachment") }
    public enum Actions {
      /// Copy Message
      public static var copy: String { L10n.tr("Localizable", "message.actions.copy") }
      /// Delete Message
      public static var delete: String { L10n.tr("Localizable", "message.actions.delete") }
      /// Download
      public static var download: String { L10n.tr("Localizable", "message.actions.download") }
      /// Edit Message
      public static var edit: String { L10n.tr("Localizable", "message.actions.edit") }
      /// Flag Message
      public static var flag: String { L10n.tr("Localizable", "message.actions.flag") }
      /// Forward
      public static var forward: String { L10n.tr("Localizable", "message.actions.forward") }
      /// Reply
      public static var inlineReply: String { L10n.tr("Localizable", "message.actions.inline-reply") }
      /// Mark as unread
      public static var markUnread: String { L10n.tr("Localizable", "message.actions.mark-unread") }
      /// Pin
      public static var pin: String { L10n.tr("Localizable", "message.actions.pin") }
      /// Resend
      public static var resend: String { L10n.tr("Localizable", "message.actions.resend") }
      /// Thread Reply
      public static var threadReply: String { L10n.tr("Localizable", "message.actions.thread-reply") }
      /// Unpin
      public static var unpin: String { L10n.tr("Localizable", "message.actions.unpin") }
      /// Block User
      public static var userBlock: String { L10n.tr("Localizable", "message.actions.user-block") }
      /// Mute User
      public static var userMute: String { L10n.tr("Localizable", "message.actions.user-mute") }
      /// Unblock User
      public static var userUnblock: String { L10n.tr("Localizable", "message.actions.user-unblock") }
      /// Unmute User
      public static var userUnmute: String { L10n.tr("Localizable", "message.actions.user-unmute") }
      public enum Copy {
        /// Message copied to clipboard.
        public static var successTitle: String { L10n.tr("Localizable", "message.actions.copy.success-title") }
      }
      public enum Delete {
        /// Are you sure you want to permanently delete this message?
        public static var confirmationMessage: String { L10n.tr("Localizable", "message.actions.delete.confirmation-message") }
        /// Delete Message
        public static var confirmationTitle: String { L10n.tr("Localizable", "message.actions.delete.confirmation-title") }
      }
      public enum Download {
        /// Download failed. Please try again later.
        public static var failureTitle: String { L10n.tr("Localizable", "message.actions.download.failure-title") }
        /// Download successful.
        public static var successTitle: String { L10n.tr("Localizable", "message.actions.download.success-title") }
      }
      public enum Flag {
        /// Do you want to send a copy of this message to a moderator for further investigation?
        public static var confirmationMessage: String { L10n.tr("Localizable", "message.actions.flag.confirmation-message") }
        /// Flag Message
        public static var confirmationTitle: String { L10n.tr("Localizable", "message.actions.flag.confirmation-title") }
      }
      public enum Forward {
        /// Unable to forward the message. Please try again.
        public static var failureTitle: String { L10n.tr("Localizable", "message.actions.forward.failure-title") }
        /// Message forwarded successfully.
        public static var successTitle: String { L10n.tr("Localizable", "message.actions.forward.success-title") }
      }
      public enum Pin {
        /// Message pinned.
        public static var successMessage: String { L10n.tr("Localizable", "message.actions.pin.success-message") }
        /// Unable to pin the message. Please try again.
        public static var unsuccessMessage: String { L10n.tr("Localizable", "message.actions.pin.unsuccess-message") }
      }
      public enum Unpin {
        /// Are you sure you want to unpin this message? It will no longer appear at the top of the conversation.
        public static var confirmationMessage: String { L10n.tr("Localizable", "message.actions.unpin.confirmation-message") }
        /// Unpin this message?
        public static var confirmationTitle: String { L10n.tr("Localizable", "message.actions.unpin.confirmation-title") }
        /// Message unpinned.
        public static var successMessage: String { L10n.tr("Localizable", "message.actions.unpin.success-message") }
        /// Unable to unpin the message. Please try again.
        public static var unsuccessMessage: String { L10n.tr("Localizable", "message.actions.unpin.unsuccess-message") }
      }
    }
    public enum Call {
      /// You cancel audio call
      public static var audioCanceledByMe: String { L10n.tr("Localizable", "message.call.audio-canceled-by-me") }
      /// You rejected audio call
      public static var audioRejectedByMe: String { L10n.tr("Localizable", "message.call.audio-rejected-by-me") }
      /// Receiver rejected audio call
      public static var audioRejectedByReceiver: String { L10n.tr("Localizable", "message.call.audio-rejected-by-receiver") }
      /// Incoming audio call
      public static var incomingAudioCall: String { L10n.tr("Localizable", "message.call.incoming-audio-call") }
      /// Incoming video call
      public static var incomingVideoCall: String { L10n.tr("Localizable", "message.call.incoming-video-call") }
      /// You missed audio call
      public static var missedAudioCall: String { L10n.tr("Localizable", "message.call.missed-audio-call") }
      /// You missed video call
      public static var missedVideoCall: String { L10n.tr("Localizable", "message.call.missed-video-call") }
      /// Outgoing audio call
      public static var outgoingAudioCall: String { L10n.tr("Localizable", "message.call.outgoing-audio-call") }
      /// Outgoing video call
      public static var outgoingVideoCall: String { L10n.tr("Localizable", "message.call.outgoing-video-call") }
      /// Receiver was busy
      public static var receiverBusy: String { L10n.tr("Localizable", "message.call.receiver-busy") }
      /// You cancel video call
      public static var videoCanceledByMe: String { L10n.tr("Localizable", "message.call.video-canceled-by-me") }
      /// You rejected video call
      public static var videoRejectedByMe: String { L10n.tr("Localizable", "message.call.video-rejected-by-me") }
      /// Receiver rejected video call
      public static var videoRejectedByReceiver: String { L10n.tr("Localizable", "message.call.video-rejected-by-receiver") }
    }
    public enum Moderation {
      /// Delete Message
      public static var delete: String { L10n.tr("Localizable", "message.moderation.delete") }
      /// Edit Message
      public static var edit: String { L10n.tr("Localizable", "message.moderation.edit") }
      /// Consider how your comment might make others feel and be sure to follow our Community Guidelines.
      public static var message: String { L10n.tr("Localizable", "message.moderation.message") }
      /// Send Anyway
      public static var resend: String { L10n.tr("Localizable", "message.moderation.resend") }
      /// Are you sure?
      public static var title: String { L10n.tr("Localizable", "message.moderation.title") }
    }
    public enum Sending {
      /// UPLOADING FAILED
      public static var attachmentUploadingFailed: String { L10n.tr("Localizable", "message.sending.attachment-uploading-failed") }
    }
    public enum System {
      /// Cooldown feature enabled by Group Admin. Cooldown duration set to %@
      public static func adjustCooldown(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.adjust-cooldown", String(describing: p1))
      }
      /// %@ changed the group description
      public static func channelDesciptionUpdated(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.channel-desciption-updated", String(describing: p1))
      }
      /// %@ changed the group avatar
      public static func channelImageUpdated(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.channel-image-updated", String(describing: p1))
      }
      /// %@ changed the group name to "%@"
      public static func channelNameUpdated(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "message.system.channel-name-updated", String(describing: p1), String(describing: p2))
      }
      /// %@ update group filter words
      public static func filterWordsChanged(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.filter-words-changed", String(describing: p1))
      }
      /// %@ banned from interacting in this group by Group Admin
      public static func memberBanned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-banned", String(describing: p1))
      }
      /// %@ removed as the moderator from this group
      public static func memberDemoted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-demoted", String(describing: p1))
      }
      /// %@ joined this group
      public static func memberJoinedChannel(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-joined-channel", String(describing: p1))
      }
      /// %@ joined this conversation
      public static func memberJoinedConversation(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-joined-conversation", String(describing: p1))
      }
      /// %@ left this group
      public static func memberLeave(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-leave", String(describing: p1))
      }
      /// %@ assigned as the moderator for this group
      public static func memberPromoted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-promoted", String(describing: p1))
      }
      /// %@ removed from this group
      public static func memberRemoved(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-removed", String(describing: p1))
      }
      /// %@ unbanned and now can interact in this group
      public static func memberUnbanned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.member-unbanned", String(describing: p1))
      }
      /// A message has been forwarded
      public static var messageForwarded: String { L10n.tr("Localizable", "message.system.message-forwarded") }
      /// %@ pinned a message
      public static func messagePinned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.message-pinned", String(describing: p1))
      }
      /// %@ unpinned a message
      public static func messageUnpinned(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.message-unpinned", String(describing: p1))
      }
      /// %@ has promoted you to Owner
      public static func otherPromotedYouToOwner(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.other-promoted-you-to-owner", String(describing: p1))
      }
      /// %@ rejected to join this channel.
      public static func otherRejectAddFriendRequest(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.other-reject-add-friend-request", String(describing: p1))
      }
      /// %@ truncated all messages of this channel
      public static func otherTruncatedMessages(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.other-truncated-messages", String(describing: p1))
      }
      /// %@ updated member permission of group
      public static func otherUpdatedMemberPermission(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.other-updated-member-permission", String(describing: p1))
      }
      /// %@ has promoted member %@ to Owner
      public static func promotedToOwner(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "message.system.promoted-to-owner", String(describing: p1), String(describing: p2))
      }
      /// Member %@ made this group private
      public static func setChannelPrivate(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.set-channel-private", String(describing: p1))
      }
      /// Member %@ made this group public
      public static func setChannelPublic(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.set-channel-public", String(describing: p1))
      }
      /// Cooldown has been disabled
      public static var turnOffCooldown: String { L10n.tr("Localizable", "message.system.turn-off-cooldown") }
      /// Cooldown feature enabled by Group Admin. Cooldown duration set to %@
      public static func turnOnCooldown(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.turn-on-cooldown", String(describing: p1))
      }
      /// %@ declined to join this group
      public static func userRejectedInvitation(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.user-rejected-invitation", String(describing: p1))
      }
      /// You banned from interacting in this group by Group Admin
      public static var youBanned: String { L10n.tr("Localizable", "message.system.you-banned") }
      /// You removed as the moderator from this group
      public static var youDemoted: String { L10n.tr("Localizable", "message.system.you-demoted") }
      /// You joined this group
      public static var youJoinedChannel: String { L10n.tr("Localizable", "message.system.you-joined-channel") }
      /// You joined this conversation
      public static var youJoinedConversation: String { L10n.tr("Localizable", "message.system.you-joined-conversation") }
      /// You left this group
      public static var youLeave: String { L10n.tr("Localizable", "message.system.you-leave") }
      /// You assigned as the moderator for this group
      public static var youPromoted: String { L10n.tr("Localizable", "message.system.you-promoted") }
      /// You have promoted member %@ to Owner
      public static func youPromotedOtherToOwner(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.you-promoted-other-to-owner", String(describing: p1))
      }
      /// You rejected friend request from %@
      public static func youRejectAddFriendRequest(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.system.you-reject-add-friend-request", String(describing: p1))
      }
      /// You made this group private
      public static var youSetChannelPrivate: String { L10n.tr("Localizable", "message.system.you-set-channel-private") }
      /// You made this group public
      public static var youSetChannelPublic: String { L10n.tr("Localizable", "message.system.you-set-channel-public") }
      /// You truncated all messages of this channel
      public static var youTruncatedMessages: String { L10n.tr("Localizable", "message.system.you-truncated-messages") }
      /// You unbanned and now can interact in this group
      public static var youUnbanned: String { L10n.tr("Localizable", "message.system.you-unbanned") }
      /// You updated member permission of group
      public static var youUpdatedMemberPermission: String { L10n.tr("Localizable", "message.system.you-updated-member-permission") }
      /// You have forwarded a message
      public static var yourMessageForwarded: String { L10n.tr("Localizable", "message.system.your-message-forwarded") }
    }
    public enum Thread {
      public enum Replies {
        /// Plural format key: "%#@replies@"
        public static func count(_ p1: Int) -> String {
          return L10n.tr("Localizable", "message.thread.replies.count", p1)
        }
      }
    }
    public enum Threads {
      /// Plural format key: "%#@replies@"
      public static func count(_ p1: Int) -> String {
        return L10n.tr("Localizable", "message.threads.count", p1)
      }
      /// Thread Reply
      public static var reply: String { L10n.tr("Localizable", "message.threads.reply") }
      /// with %@
      public static func replyWith(_ p1: Any) -> String {
        return L10n.tr("Localizable", "message.threads.replyWith", String(describing: p1))
      }
    }
    public enum Title {
      /// %d members
      public static func group(_ p1: Int) -> String {
        return L10n.tr("Localizable", "message.title.group", p1)
      }
      /// Offline
      public static var offline: String { L10n.tr("Localizable", "message.title.offline") }
      /// Online
      public static var online: String { L10n.tr("Localizable", "message.title.online") }
    }
    public enum Unread {
      /// Plural format key: "%#@unread@"
      public static func count(_ p1: Int) -> String {
        return L10n.tr("Localizable", "message.unread.count", p1)
      }
    }
  }

  public enum MessageList {
    /// Plural format key: "%#@unreads@"
    public static func jumpToUnreadButton(_ p1: Int) -> String {
      return L10n.tr("Localizable", "messageList.jump-to-unread-button", p1)
    }
    public enum TypingIndicator {
      /// Someone is typing
      public static var typingUnknown: String { L10n.tr("Localizable", "messageList.typingIndicator.typing-unknown") }
      /// Plural format key: "%1$@%2$#@typing@"
      public static func users(_ p1: Any, _ p2: Int) -> String {
        return L10n.tr("Localizable", "messageList.typingIndicator.users", String(describing: p1), p2)
      }
    }
  }

  public enum Pin {
    public enum Collapsed {
      /// Pinned messages
      public static var title: String { L10n.tr("Localizable", "pin.collapsed.title") }
    }
  }

  public enum Reaction {
    public enum Authors {
      /// Plural format key: "%#@reactions@"
      public static func numberOfReactions(_ p1: Int) -> String {
        return L10n.tr("Localizable", "reaction.authors.number-of-reactions", p1)
      }
    }
  }

  public enum Recording {
    /// Slide to cancel
    public static var slideToCancel: String { L10n.tr("Localizable", "recording.slideToCancel") }
    /// Hold to record, release to send
    public static var tip: String { L10n.tr("Localizable", "recording.tip") }
    public enum Presentation {
      /// Plural format key: "%#@recording@"
      public static func name(_ p1: Int) -> String {
        return L10n.tr("Localizable", "recording.presentation.name", p1)
      }
    }
  }

  public enum Share {
    /// Send to
    public static var sendTo: String { L10n.tr("Localizable", "share.send-to") }
  }

  public enum Topic {
    /// THIS TOPIC IS CLOSED
    public static var closed: String { L10n.tr("Localizable", "topic.closed") }
    /// General
    public static var parentChannelDisplayName: String { L10n.tr("Localizable", "topic.parent-channel-display-name") }
    /// Reopen Topic
    public static var reOpen: String { L10n.tr("Localizable", "topic.re-open") }
    public enum CloseAlert {
      /// Are you sure you want to close this topic?
      public static var message: String { L10n.tr("Localizable", "topic.close-alert.message") }
      /// Close Topic
      public static var title: String { L10n.tr("Localizable", "topic.close-alert.title") }
    }
    public enum ReOpenAlert {
      /// Are you sure you want to reopen this topic?
      public static var message: String { L10n.tr("Localizable", "topic.re-open-alert.message") }
      /// Reopen Topic
      public static var title: String { L10n.tr("Localizable", "topic.re-open-alert.title") }
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

