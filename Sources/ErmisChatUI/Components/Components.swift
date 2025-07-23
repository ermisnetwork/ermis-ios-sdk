//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// An object containing types of UI Components that are used through the UI SDK.
public struct Components {

    /// A view that displays the avatar image.
    public var avatarView: AvatarView.Type = AvatarView.self

    /// The view that shows current user avatar.
    public var currentUserAvatarView: CurrentUserAvatarView.Type = CurrentUserAvatarView.self

    /// An avatar view with an online indicator.
    public var presenceAvatarView: PresenceAvatarView.Type = PresenceAvatarView.self

    /// An avatar view that show combined images.
    public var combinedAvatarView: CombineAvatarView.Type = CombineAvatarView.self

    /// A view used as an online activity indicator (online/offline).
    public var onlineIndicatorView: (UIView & MaskProviding).Type = OnlineIndicatorView.self

    /// The default avatar thumbnail size.
    public var avatarThumbnailSize: CGSize = .init(width: 40, height: 40)

    /// A view for showing a cooldown when Slow Mode is active.
    public var cooldownView: CooldownView.Type = CooldownView.self

    /// A view for inputting text with placeholder support.
    public var inputTextView: InputTextView.Type = InputTextView.self

    /// A view to input content of a message.
    public var inputMessageView: InputMessageView.Type = InputMessageView.self

    /// A view that displays a quoted message.
    public var quotedMessageView: QuotedMessageView.Type = QuotedMessageView.self

    /// A view that displays a title label and subtitle in a container stack view.
    public var titleContainerView: TitleContainerView.Type = TitleContainerView.self

    /// A `UIView` subclass which serves as container for `typingIndicator` and `UILabel` describing who is currently typing
    public var typingIndicatorView: TypingIndicatorView.Type = TypingIndicatorView.self

    /// A `UIView` subclass with animated 3 dots for indicating that user is typing.
    public var typingAnimationView: TypingAnimationView.Type = TypingAnimationView.self

    /// A view that displays the command name and icon.
    public var commandLabelView: CommandLabelView.Type = CommandLabelView.self

    /// A view that displays the link in the composer.
    public var composerLinkPreviewView: ComposerLinkPreviewView.Type = ComposerLinkPreviewView.self

    /// A boolean value that determines whether the link preview should show when typing a message with links.
    public var isComposerLinkPreviewEnabled = true

    /// A view show when calls are happen, this will help user back to call screen.
    public var ongoingCallVIew: OngoingCallView.Type = OngoingCallView.self

    /// A button for choosing emoji and sticker.
    public var stickerButton: UIButton.Type = StickerButton.self

    /// A button for choosing photos.
    public var photoButton: UIButton.Type = PhotoButton.self

    /// A button for opening command list.
    public var commandsButton: UIButton.Type = CommandButton.self

    /// A button for showing actions menu in composer..
    public var composerMenu: ComposerMenuButton.Type = ComposerMenuButton.self

    /// A button used for sending a message.
    public var sendButton: UIButton.Type = SendButton.self

    /// A button used for recording a voice message.
    public var recordButton: RecordButton.Type = RecordButton.self

    /// A button for closing, dismissing or clearing information.
    public var closeButton: UIButton.Type = CloseButton.self

    /// A button for confirming actions.
    public var confirmButton: UIButton.Type = ConfirmButton.self

    /// A button for sharing an information.
    public var shareButton: UIButton.Type = ShareButton.self

    /// A button for download content.
    public var downloadButton: UIButton.Type = DownloadButton.self

    /// A view used as a fallback preview view for attachments.
    public var attachmentPreviewViewPlaceholder: UIView.Type = AttachmentPlaceholderView.self

    /// The view that shows a playing video.
    public var playerView: PlayerView.Type = PlayerView.self

    /// The view that shows a gradient.
    public var gradientView: GradientView.Type = GradientView.self

    /// The view that shows a loading indicator.
    public var loadingIndicator: LoadingIndicator.Type = LoadingIndicator.self

    /// Object which is responsible for loading images
    public var imageLoader: ImageLoading = NukeImageLoader()

    /// Object responsible for providing resizing operations for `UIImage`
    public var imageProcessor: ImageProcessor = NukeImageProcessor()

    /// The object responsible for loading video attachments.
    public var videoLoader: VideoLoading = ErmisVideoLoader()

    /// Object with set of function for handling images from CDN
    public var imageCDN: ImageCDN = ErmisImageCDN()

    // The view that displays a banner to show the count of messages
    public var messagesCountDecorationView: MessagesCountDecorationView.Type = MessagesCountDecorationView.self

    /// An object responsible for message layout options calculations in `MessageListViewController/ThreadViewController`.
    public var messageLayoutOptionsResolver: MessageLayoutOptionsResolver = .init()

    // MARK: - Message List components

    /// The view controller responsible for rendering a list of messages.
    /// Used in both the Channel and Thread view controllers.
    @available(iOSApplicationExtension, unavailable)
    public var messageListVC: MessageListViewController.Type = MessageListViewController.self

    /// The foundation view for the message list view controller.
    public var messageListView: MessageListView.Type = MessageListView.self

    /// The view that is displayed as top overlay when message list is scrolling.
    public var messageListScrollOverlayView: MessageListScrollOverlayView.Type =
        MessageListScrollOverlayView.self

    /// The date separator view that groups messages from the same day.
    public var messageListDateSeparatorView: MessageListDateSeparatorView.Type = MessageListDateSeparatorView.self

    /// A boolean value that determines whether the messages should start at the top
    /// of the list  when there are few messages. By default it is `false`.
    public var shouldMessagesStartAtTheTop: Bool = false

    /// Whether it should animate when opening the channel with a given message around id.
    /// Ex: When opening a channel from a push notification with a given message id.
    public var shouldAnimateJumpToMessageWhenOpeningChannel: Bool = true

    /// Whether it should jump to the unread message when the channel is initially opened.
    /// By default it is disabled.
    public var shouldJumpToUnreadWhenOpeningChannel: Bool = false

    /// A boolean value that determines whether the date overlay should be displayed while scrolling.
    public var messageListDateOverlayEnabled = true

    /// A boolean value that determines whether date separators should be shown between each message.
    public var messageListDateSeparatorEnabled = false

    /// A boolean value that determines whether swiping to quote reply is available.
    public var messageSwipeToReplyEnabled = false

    /// A boolean value that determines whether automatic translation is enabled.
    public var messageAutoTranslationEnabled = false

    /// The view controller used to perform message actions.
    public var messageActionsVC: MessageActionsViewController.Type = MessageActionsViewController.self

    /// The view controller that is presented when long-pressing a message.
    public var messagePopupVC: MessagePopupViewController.Type = MessagePopupViewController.self

    /// The view controller used for showing preview of a message attachment.
    public var filePreviewVC: MessageAttachmentPreviewViewController.Type = MessageAttachmentPreviewViewController.self

    /// The view controller to showcase and slide through multiple attachments.
    public var galleryVC: GalleryViewController.Type = GalleryViewController.self

    /// The view used to control the player for currently visible vide attachment.
    public var videoPlaybackControlView: VideoPlaybackControlView.Type =
        VideoPlaybackControlView.self

    /// The view used to display content of the message.
    public var messageContentView: MessageContentView.Type = MessageContentView.self

    /// The view used to display a bubble around a message.
    public var messageBubbleView: MessageBubbleView.Type = MessageBubbleView.self

    /// The maximum image resolution in pixels when loading image attachments in the Message List.
    ///
    /// By default it is 2MP, 2 Million Pixels. Keep in mind that
    /// increasing this value will increase the memory footprint.
    public var imageAttachmentMaxPixels: Double = 2_000_000

    /// The class responsible for returning the correct custom cell view injector from a message
    @available(iOSApplicationExtension, unavailable)
    public var customCellViewCatalog: CustomCellViewCatalog.Type = CustomCellViewCatalog.self

    /// The injector used for injecting file attachment views.
    public var filesAttachmentInjector: CustomCellViewInjector.Type = FilesAttachmentViewInjector.self

    /// The injector used to inject gallery attachment views.
    public var galleryAttachmentInjector: CustomCellViewInjector.Type = GalleryAttachmentViewInjector.self

    /// The injector used to combine multiple types of attachment views.
    /// By default, it is a combination of a file injector and a gallery injector.
    public var mixedAttachmentInjector: MixedAttachmentViewInjector.Type = MixedAttachmentViewInjector.self

    /// The injector used to inject link attachment views.
    @available(iOSApplicationExtension, unavailable)
    public var linkAttachmentInjector: CustomCellViewInjector.Type = LinkAttachmentViewInjector.self

    /// The injector used for injecting unsupported attachment views.
    public var unsupportedAttachmentInjector: CustomCellViewInjector.Type = UnsupportedAttachmentViewInjector.self

    /// The injector used for injecting voice recording attachment views.
    public var voiceRecordingAttachmentInjector: CustomCellViewInjector.Type = VoiceRecordingAttachmentViewInjector.self

    /// The injector used for injecting call views.
    public var callViewInjector: CustomCellViewInjector.Type = CallViewInjector.self

    /// The button for taking an action on attachment being uploaded.
    public var attachmentActionButton: AttachmentActionButton.Type = AttachmentActionButton.self

    /// The view that shows error indicator in `messageContentView`.
    public var messageErrorIndicator: MessageErrorIndicator.Type = MessageErrorIndicator.self

    /// The view that shows message's file attachments.
    public var fileAttachmentListView: MessageFileAttachmentListView
        .Type = MessageFileAttachmentListView.self

    /// The view that shows a single file attachment.
    public var fileAttachmentView: MessageFileAttachmentListView.ItemView.Type =
    MessageFileAttachmentListView.ItemView.self

    /// The view that shows message's voiceRecording attachments.
    public var voiceRecordingAttachmentListView: MessageVoiceRecordingAttachmentListView
        .Type = MessageVoiceRecordingAttachmentListView.self

    /// The view that shows a single voiceRecording attachment.
    public var voiceRecordingAttachmentView: MessageVoiceRecordingAttachmentListView.ItemView.Type =
        MessageVoiceRecordingAttachmentListView.ItemView.self

    /// The view that shows a link preview in message cell.
    public var linkPreviewView: MessageLinkPreviewView.Type =
        MessageLinkPreviewView.self

    /// The view that shows message's image and video attachments.
    public var galleryView: MessageGalleryView.Type = MessageGalleryView.self

    /// The view that shows an image attachment preview inside message cell.
    public var imageAttachmentGalleryPreview: MessageGalleryView.ImagePreview.Type = MessageGalleryView.ImagePreview.self

    /// The view that shows a gif image attachment preview inside message cell.
    public var gifImageAttachmentGalleryPreview: MessageGalleryView.GifImagePreview.Type = MessageGalleryView.GifImagePreview.self

    /// The view that shows an image attachment in full-screen gallery.
    public var imageAttachmentGalleryCell: ImageAttachmentGalleryCell.Type = ImageAttachmentGalleryCell.self

    /// The view that shows a video attachment in full-screen gallery.
    public var videoAttachmentGalleryCell: VideoAttachmentGalleryCell.Type = VideoAttachmentGalleryCell.self

    /// The view that shows a video attachment preview inside a message.
    public var videoAttachmentGalleryPreview: VideoAttachmentGalleryPreview.Type = VideoAttachmentGalleryPreview.self

    /// The view that displays the voice recording attachment preview in composer.
    public var voiceRecordingAttachmentComposerPreview: VoiceRecordingAttachmentComposerPreview
        .Type = VoiceRecordingAttachmentComposerPreview.self

    /// The view that displays the voice recording attachment as a quoted preview in composer.
    public var voiceRecordingAttachmentQuotedPreview: VoiceRecordingAttachmentQuotedPreview
        .Type = VoiceRecordingAttachmentQuotedPreview.self

    /// The view that shows an overlay with uploading progress for image attachment that is being uploaded.
    public var uploadingOverlayView: UploadingOverlayView.Type = UploadingOverlayView.self

    /// The view that show call details in the message cell.
    public var callView: CallView.Type  = CallView.self

    /// The view that shows messages delivery status.
    public var messageDeliveryStatusView: MessageDeliveryStatusView.Type =
        MessageDeliveryStatusView.self

    /// The view that shows messages delivery status checkmark.
    public var messageDeliveryStatusCheckmarkView: MessageDeliveryStatusCheckmarkView.Type =
        MessageDeliveryStatusCheckmarkView.self

    /// A flag which determines if an unread messages separator should be displayed when there are new messages.
    public var isUnreadMessagesSeparatorEnabled = true

    /// The view that displays the number of unread messages in the chat.
    public var unreadMessagesCounterDecorationView: UnreadMessagesCountDecorationView.Type = UnreadMessagesCountDecorationView.self

    /// The button that indicates unread messages at the bottom of the message list and scroll to the bottom on tap.
    public var scrollToBottomButton: ScrollToBottomButton.Type = ScrollToBottomButton.self

    /// The button that shows when there are unread messages outside the bounds of the screen. Can be tapped to scroll to them, or can be discarded.
    public var jumpToUnreadMessagesButton: JumpToUnreadMessagesButton.Type = JumpToUnreadMessagesButton.self

    /// The view that shows a number of unread messages on the Scroll-To-Latest-Message button in the Message List.
    public var messageListUnreadCountView: MessageListUnreadCountView.Type =
    MessageListUnreadCountView.self

    /// A flag which determines if `Jump to unread` feature will be enabled.
    public var isJumpToUnreadEnabled = false

    /// A flag which determines if edited messages should show a "Edited" label.
    /// It is disabled by default.
    public var isMessageEditedLabelEnabled = false

    /// The view that displays the number of unread messages in the chat.
    public var messageHeaderDecorationView: ChannelMessageHeaderDecoratorView.Type = ChannelMessageHeaderDecoratorView.self

    /// The controller that handles `MessageListViewController <-> MessagePopUp` transition.
    public var messageActionsTransitionController: MessageActionsTransitionController.Type =
    MessageActionsTransitionController.self

    // MARK: - Reactions

    /// The view that shows reactions of a message. This is used by the message component.
    public var messageReactionsBubbleView: ReactionBubbleBaseView.Type = ReactionsBubbleView.self

    /// The view that shows the list of reactions attached to the message.
    public var messageReactionsView: MessageReactionsView.Type = MessageReactionsView.self

    /// The view that renders a single reaction attached to the message.
    public var messageReactionItemView: MessageReactionItemView.Type = MessageReactionItemView.self

    /// The Reaction picker View controller.
    public var reactionPickerVC: MessageReactionsPickerViewController.Type = MessageReactionsPickerViewController.self

    /// The view that shows reactions bubble.
    public var reactionPickerBubbleView: ReactionPickerBubbleView.Type = DefaultReactionPickerBubbleView.self

    /// The view that shows the list of reaction toggles/buttons.
    public var reactionPickerReactionsView: MessageReactionsView.Type = ReactionPickerReactionsView.self

    /// The view that renders a single reaction view button.
    public var reactionPickerReactionItemView: MessageReactionItemView.Type = MessageReactionItemView.self

    /// The view controller that renders the reaction and it's author avatar for all the reactions of a message.
    public var reactionAuthorsVC: MessageReactionAuthorsViewController.Type = MessageReactionAuthorsViewController.self

    /// The view cell that displays an individual reaction author of a message.
    public var reactionAuthorCell: MessageReactionAuthorViewCell.Type = MessageReactionAuthorViewCell.self

    /// The sorting order of how the reactions data will be displayed.
    public var reactionsSorting: ((MessageReactionData, MessageReactionData) -> Bool) = {
        $0.type.rawValue < $1.type.rawValue
    }

    // MARK: - Thread components

    /// The view controller used to display the detail of a message thread.
    public var threadVC: ThreadViewController.Type = ThreadViewController.self

    /// The view that displays channel information on the thread header.
    public var threadHeaderView: ThreadHeaderView.Type = ThreadHeaderView.self

    /// The view that displays the number of replies in the current thread.
    public var threadRepliesCounterDecorationView: ThreadRepliesCountDecorationView.Type = ThreadRepliesCountDecorationView.self

    /// A boolean value that determines whether thread replies counter decoration should be shown below the source message of a thread.
    public var threadRepliesCounterEnabled = true

    /// A boolean value that determines whether the thread view renders the parent message at the top.
    public var threadRendersParentMessageEnabled = true

    /// A boolean value that determines if thread replies start from the oldest replies.
    /// By default it is false, and newest replies are rendered in the first page.
    public var threadRepliesStartFromOldest = false

    // MARK: - Channel components

    /// The view controller that contains the channel messages and represents the chat view.
    public var channelVC: ChannelViewController.Type = ChannelViewController.self

    /// The view that displays channel information on the channel header.
    public var channelHeaderView: ChannelHeaderView.Type = ChannelHeaderView.self

    /// The view that displays notice message when direct user is not joined channel yet.
    public var channelInvitingView: ChannelInvitingView.Type = ChannelInvitingView.self

    /// The view that display invitation action to join or reject in invited room.
    public var channelAcceptInvitationView: ChannelAcceptInvitationView.Type = ChannelAcceptInvitationView.self

    /// The collection view layout of the channel list.
    public var channelListLayout: UICollectionViewLayout.Type = ListCollectionViewLayout.self

    /// The cell of channel list that show channel informations.
    public var channelListCell: ChannelListCollectionViewCell.Type = ChannelListCollectionViewCell.self

    /// The cell separator in the channel list.
    public var channelCellSeparator: UICollectionReusableView.Type = CellSeparatorReusableView.self

    /// The view in the channel cell that shows channel actions on swipe.
    public var channelActionsView: SwipeableView.Type = SwipeableView.self

    /// The view that shows channel information.
    public var channelListItemContentView: ChannelListItemView.Type = ChannelListItemView.self

    /// The cell that shows invited channel information.
    public var invitedChannelCell: InvitedChannelCollectionViewCell.Type = InvitedChannelCollectionViewCell.self

    /// The view that shows invited channel.
    public var invitedChannelContentView: InvitedChannelListItemView.Type = InvitedChannelListItemView.self

    /// The cell that show contact (direct channel) infomation.
    public var contactListCell: ContactListCollectionViewCell.Type = ContactListCollectionViewCell.self

    /// The view that show contact.
    public var contactListContentView: ContactListItemView.Type = ContactListItemView.self

    /// The view that show section header in contact list screen.
    public var contactListSectionHeader: ContactListSectionHeader.Type = ContactListSectionHeader.self

    /// The view that shows the channel avatar (include an indicator of the user presence).
    public var channelAvatarView: ChannelAvatarView.Type = ChannelAvatarView.self

    /// The view that shows a number of unread messages in channel.
    public var channelUnreadCountView: UnreadCountView.Type = UnreadCountView.self

    /// The view that is displayed when channel list is empty.
    public var channelListEmptyView: ChannelListEmptyView.Type = ChannelListEmptyView.self

    /// The view that is displayed when invited channel list is empty.
    public var invitedChannelListEmptyView: InvitedChannelListEmptyView.Type = InvitedChannelListEmptyView.self

    /// The view that is displayed when contact list is empty.
    public var contactListEmptyView: ContactListEmptyView.Type = ContactListEmptyView.self

    /// The view that shows when some error occurred on ChannelList.
    public var channelListErrorView: ChannelListErrorView.Type = ChannelListErrorView.self

    /// The view that shows when loading the Channel list.
    public var channelListLoadingView: ChannelListLoadingView.Type = ChannelListLoadingView.self

    /// The cell display skeleton loading.
    public var channelListLoadingViewCell: ChannelListLoadingViewCell.Type = ChannelListLoadingViewCell.self

    /// The content view inside the cell responsible to display a skeleton loading view.
    public var channelListLoadingContentViewCell: ChannelListLoadingViewCellContentView.Type = ChannelListLoadingViewCellContentView.self

    /// The content view show required condition to join channel alert.
    public var channelConditionRequiredView: ChannelConditionRequiredView.Type = ChannelConditionRequiredView.self

    /// The cell that show required condition to join channel.
    public var channelConditionRequiredCell: ChannelConditionRequiredTableViewCell.Type = ChannelConditionRequiredTableViewCell.self

    /// A boolean value that determines whether the Channel list default loading states (empty, error and loading views) are handled by the Ermis SDK. It is false by default.
    /// If it is false, it does not show empty or error views and just shows a spinner indicator for the loading state. If set to true, the empty, error and shimmer loading views are shown instead.
    public var isChannelListStatesEnabled = false
    /// A boolean value that determines whether the Channel list default loading states (empty, error and loading views) are handled by the Ermis SDK. It is false by default.
    /// If it is false, it does not show empty or error views and just shows a spinner indicator for the loading state. If set to true, the empty, error and shimmer loading views are shown instead.
    public var isInvitedChannelListStatesEnabled = false

    // MARK: - Channel Search

    /// The channel list search type. By default, search is disabled so it is `nil`.
    ///
    /// To enable searching by messages you can provide the following strategy:
    /// ```
    /// // With default UI Component
    /// Components.default.channelListSearchType = .messages
    /// // With custom UI Component
    /// Components.default.channelListSearchType = .messages(CustomMessageSearchVC.self)
    /// ```
    ///
    /// To enable searching by channels you can provide the following strategy:
    /// ```
    /// // With default UI Component
    /// Components.default.channelListSearchType = .channels
    /// // With custom UI Component
    /// Components.default.channelListSearchType = .channels(CustomChannelSearchViewController.self)
    /// ```
    public var channelListSearchType: ChannelListSearchType?

    public var invitedChannelListSearchType: ChannelListSearchType?

    public var contactlistSearchType: ChannelListSearchType?

    // MARK: - Forwarding

    /// The view show detail of channel in forwarding message screen.
    public var forwardingItemView: ForwardingMessageItemView.Type = ForwardingMessageItemView.self
    /// The cell show detail of channel in forwarding message screen.
    public var forwardingMessageCell: ForwardingMessageCell.Type = ForwardingMessageCell.self
    /// The view controller used to select channel which message will be forwarded.
    public var forwardingMessageViewController: ForwardingMessageViewController.Type = ForwardingMessageViewController.self

    // MARK: - Share

//    /// The view show details of channel in share screen.
//    public var shareItemView: ShareItemView.Type = ShareItemView.self
    /// The cell show details of channel in share screen.
//    public var shareTableViewCell: ShareTableViewCell.Type = ShareTableViewCell.self
    /// The view controller used to select channel which attachment wil be shared.
//    public var shareViewController: ShareViewController.Type = ShareViewController.self

    // MARK: - Pin
    /// The view that show lastest pinned message.
    public var pinnedMessageView: PinnedMessageView.Type = PinnedMessageView.self
    /// The view controller used to show pinned messages of a channel.
    public var pinnedMessageListViewController: PinnedMessagesViewController.Type = PinnedMessagesViewController.self
    /// The cell show detail of pinned message in `PinnedMessageViewController`.
    public var pinnedMessageCell: PinnedMessageCell.Type = PinnedMessageCell.self
    /// The view show detail of pinned message in `PinnedMessageCell`.
    public var pinnedMessageListItemView: PinnedMessageListItemView.Type = PinnedMessageListItemView.self

    // MARK: - Edited messages
    /// The view controller used to show edited history of a message.
    public var editedMessageListViewController: EditedMessageListViewController.Type = EditedMessageListViewController.self
    /// The cell show detail of edited message in `EditedMessageListViewController`.
    public var editedMessageCell: EditedMessageCell.Type = EditedMessageCell.self
    /// The view show detail of pinned message in `PinnedMessageCell`.
    public var editedMessageListItemView: EditedMessageListItemView.Type = EditedMessageListItemView.self
    // MARK: - Composer components

    /// The view controller used to compose a message.
    public var messageComposerVC: ComposerViewController.Type = ComposerViewController.self

    /// The view that shows the message when it's being composed.
    public var messageComposerView: ComposerView.Type = ComposerView.self

    // The view that shows blocked message when the channel is blocked.
    public var messageComposerBlockedView: ComposerBlockedView.Type = ComposerBlockedView.self

    // The view that shows banned message when user is banned.
    public var messageComposerBannedView: UIView.Type = ComposerBannedView.self

    // The view that shows when user is a guest.
    public var messageComposerGuestView: ComposerGuestView.Type = ComposerGuestView.self

    /// The view controller that handles the attachments.
    public var messageComposerAttachmentsVC: AttachmentsPreviewViewController.Type = AttachmentsPreviewViewController.self

    /// The view that holds the attachment views and provide extra functionality over them.
    public var messageComposerAttachmentCell: AttachmentPreviewContainer.Type = AttachmentPreviewContainer.self

    /// The view that displays the document attachment.
    public var messageComposerFileAttachmentView: FileAttachmentView.Type = FileAttachmentView.self

    /// The view that displays image attachment preview in composer.
    public var imageAttachmentComposerPreview: ImageAttachmentComposerPreview
        .Type = ImageAttachmentComposerPreview.self

    /// The view that displays the video attachment preview in composer.
    public var videoAttachmentComposerPreview: VideoAttachmentComposerPreview
        .Type = VideoAttachmentComposerPreview.self

    // MARK: - Composer suggestion components

    /// The view controller that shows suggestions of commands or mentions.
    public var suggestionsVC: SuggestionsViewController.Type = SuggestionsViewController.self

    /// When true the suggestionsVC will search users from the entire application instead of limit search to the current channel.
    public var mentionAllAppUsers: Bool = false

    /// The collection view of the suggestions view controller.
    public var suggestionsCollectionView: SuggestionsCollectionView.Type = SuggestionsCollectionView.self

    /// The view cell that displays the the suggested mention.
    public var suggestionsMentionCollectionViewCell: MentionSuggestionCollectionViewCell.Type =
        MentionSuggestionCollectionViewCell.self

    /// The view cell that displays the suggested command.
    public var suggestionsCommandCollectionViewCell: CommandSuggestionCollectionViewCell
        .Type = CommandSuggestionCollectionViewCell.self

    /// A type for view embed in cell while tagging users with @ symbol in composer.
    public var suggestionsMentionView: MentionSuggestionView.Type = MentionSuggestionView.self

    /// The view that displays the command name, image and arguments.
    public var suggestionsCommandView: CommandSuggestionView.Type =
        CommandSuggestionView.self

    /// The collection view layout of the suggestions collection view.
    public var suggestionsCollectionViewLayout: UICollectionViewLayout.Type =
        SuggestionsCollectionViewLayout.self

    /// The header reusable view of the suggestion collection view.
    public var suggestionsHeaderReusableView: UICollectionReusableView.Type = SuggestionsCollectionReusableView.self

    /// The header view of the suggestion collection view.
    public var suggestionsHeaderView: SuggestionsHeaderView.Type =
        SuggestionsHeaderView.self

    /// The view that shows a user avatar (including an indicator of the user presence).
    public var userAvatarView: UserAvatarView.Type = UserAvatarView.self

    // MARK: - Composer VoiceRecording components

    /// A flag which determines if `VoiceRecording` feature will be enabled.
    public var isVoiceRecordingEnabled = false

    /// When set to `true` recorded messages can be grouped together and send as part of one message.
    /// When set to `false`, recorded messages will be sent instantly.
    public var isVoiceRecordingConfirmationRequiredEnabled = true

    /// The View controller that handles the recording flow.
    public var voiceRecordingViewController: VoiceRecordingViewController.Type = VoiceRecordingViewController.self

    /// The AudioPlayer that will be used for the voiceRecording playback.
    public var audioPlayer: AudioPlaying.Type = ErmisAudioQueuePlayer.self

    /// The AudioRecorder that will be used to record new voiceRecordings.
    public var audioRecorder: AudioRecording.Type = ErmisAudioRecorder.self

    /// The feedbackGenerator that will be used to provide haptic feedback during the recording flow.
    public var audioSessionFeedbackGenerator: AudioSessionFeedbackGenerator.Type = ErmisAudioSessionFeedbackGenerator.self

    /// If the AudioPlayer supports queuing, this object will be asked to provide the VoiceRecording to
    /// play automatically, once the current one completes.
    public var audioQueuePlayerNextItemProvider: AudioQueuePlayerNextItemProvider.Type = AudioQueuePlayerNextItemProvider.self
    // MARK: - Navigation

    /// The navigation controller.
    public var navigationVC: NavigationViewController.Type = NavigationViewController.self

    /// The router responsible for navigation on channel list screen.
    @available(iOSApplicationExtension, unavailable)
    public var channelListRouter: ChannelListRouter.Type = ChannelListRouter.self

    /// The router responsible for navigation on message list screen.
    public var messageListRouter: MessageListRouter.Type = MessageListRouter.self

    /// The router responsible for presenting alerts.
    public var alertsRouter: AlertsRouter.Type = AlertsRouter.self

    /// The contentView of toast view.
    public var toastView: ToastView.Type = ToastView.self

    public init() {}

    public static var `default` = Components()
}
