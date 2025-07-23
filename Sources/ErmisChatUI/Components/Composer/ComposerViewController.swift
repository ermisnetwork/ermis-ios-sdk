//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit
import PhotosUI

/// The possible errors that can occur in attachment validation
public enum AttachmentValidationError: Error {
    /// The size of the attachment exceeds the max file size
    case maxFileSizeExceeded

    internal static var fileSizeMaxLimitFallback: Int64 = 100 * 1024 * 1024
}

public struct LocalAttachmentInfoKey: Hashable, Equatable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let originalImage: Self = .init(rawValue: "originalImage")
    public static let duration: Self = .init(rawValue: "duration")
    public static let waveformData: Self = .init(rawValue: "waveformData")
}

/// The possible composer states. An Enum is not used so it does not cause
/// future breaking changes and is possible to extend with new cases.
public struct ComposerState: RawRepresentable, Equatable {
    public let rawValue: String
    public var description: String { rawValue.uppercased() }

    public init(rawValue: RawValue) {
        self.rawValue = rawValue
    }

    public static var new = ComposerState(rawValue: "new")
    public static var edit = ComposerState(rawValue: "edit")
    public static var quote = ComposerState(rawValue: "quote")
    public static var recording = ComposerState(rawValue: "recording")
    public static var recordingLocked = ComposerState(rawValue: "recordingLocked")
}

/// A view controller that manages the composer view.
open class ComposerViewController: _ViewController,
                                   UIProvider,
                                   UITextViewDelegate,
                                   PHPickerViewControllerDelegate,
                                   UIImagePickerControllerDelegate,
                                   UIDocumentPickerDelegate,
                                   UINavigationControllerDelegate,
                                   InputTextViewClipboardAttachmentDelegate,
                                   VoiceRecordingDelegate,
                                   ComposerBlockedViewDelegate,
                                   ComposerGuestViewDelegate {
    
    /// The content of the composer.
    public struct Content {
        /// The text of the input text view.
        public var text: String
        /// The state of the composer.
        public let state: ComposerState
        /// The editing message if the composer is currently editing a message.
        public let editingMessage: ChatMessage?
        /// The quoting message if the composer is currently quoting a message.
        public let quotingMessage: ChatMessage?
        /// The thread parent message if the composer is currently replying in a thread.
        public var threadMessage: ChatMessage?
        /// The attachments of the message.
        public var attachments: [AnyAttachmentPayload]
        /// The mentioned users in the message.
        public var mentionedUsers: Set<ChatUser>
        /// A boolean that check is mention all in the message.
        public var hasMentionedAll: Bool
        /// The command of the message.
        public let command: Command?
        /// The current cooldown time for the Slow mode active on channel.
        public var cooldownTime: Int

        /// A boolean that checks if the message contains any content.
        public var isEmpty: Bool {
            // If there is a command and it doesn't require an arg, content is not empty
            if let command = command, command.args.isEmpty {
                return false
            }
            // All other cases
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        }

        /// A boolean that checks if the composer is replying in a thread
        public var isInsideThread: Bool { threadMessage != nil }
        /// A boolean that checks if the composer recognised already a command.
        public var hasCommand: Bool { command != nil }

        /// A boolean that checks if slow mode is on.
        public var isSlowModeOn: Bool {
            cooldownTime > 0
        }

        /// A boolean that checks if the composer is in voice recording mode.
        public var isVoiceRecording: Bool {
            state == .recording || state == .recordingLocked
        }

        /// A boolean that checks if the message only contains link attachments.
        public var hasOnlyLinkAttachments: Bool {
            let linkAttachmentsCount = attachments.filter { $0.type == .linkPreview }.count
            let onlyContainsLinkAttachments = attachments.count == linkAttachmentsCount
            return onlyContainsLinkAttachments
        }

        public init(
            text: String,
            state: ComposerState,
            editingMessage: ChatMessage?,
            quotingMessage: ChatMessage?,
            threadMessage: ChatMessage?,
            attachments: [AnyAttachmentPayload],
            mentionedUsers: Set<ChatUser>,
            mentionedAll: Bool,
            command: Command?,
            cooldownTime: Int = 0
        ) {
            self.text = text
            self.state = state
            self.editingMessage = editingMessage
            self.quotingMessage = quotingMessage
            self.threadMessage = threadMessage
            self.attachments = attachments
            self.mentionedUsers = mentionedUsers
            self.hasMentionedAll = mentionedAll
            self.command = command
            self.cooldownTime = cooldownTime
        }

        public init(with content: ComposerContent) {
            self.text = content.text
            self.state = ComposerState(rawValue: content.state)
            self.editingMessage = content.editingMessage
            self.quotingMessage = content.quotingMessage
            self.threadMessage = content.threadMessage
            self.attachments = []
            self.mentionedUsers = content.mentionUsers
            self.hasMentionedAll = content.hasMentionAll
            self.command = nil
            self.cooldownTime = 0
        }

        /// Creates a new content struct with all empty data.
        static func initial() -> Content {
            .init(
                text: "",
                state: .new,
                editingMessage: nil,
                quotingMessage: nil,
                threadMessage: nil,
                attachments: [],
                mentionedUsers: [],
                mentionedAll: false,
                command: nil,
                cooldownTime: 0
            )
        }

        /// Resets the current content state and clears the content.
        public mutating func clear() {
            self = .init(
                text: "",
                state: .new,
                editingMessage: nil,
                quotingMessage: nil,
                threadMessage: threadMessage,
                attachments: [],
                mentionedUsers: [],
                mentionedAll: false,
                command: nil,
                cooldownTime: cooldownTime
            )
        }

        /// Sets the content state to editing a message.
        ///
        /// - Parameter message: The message that the composer will edit.
        public mutating func editMessage(_ message: ChatMessage) {
            self = .init(
                text: message.text,
                state: .edit,
                editingMessage: message,
                quotingMessage: nil,
                threadMessage: threadMessage,
                attachments: message.allAttachments.toAnyAttachmentPayload(),
                mentionedUsers: message.mentionedUsers,
                mentionedAll: message.mentionedAll,
                command: command,
                cooldownTime: cooldownTime
            )
        }

        /// Sets the content state to quoting a message.
        ///
        /// - Parameter message: The message that the composer will quote.
        public mutating func quoteMessage(_ message: ChatMessage) {
            self = .init(
                text: text,
                state: .quote,
                editingMessage: nil,
                quotingMessage: message,
                threadMessage: threadMessage,
                attachments: attachments,
                mentionedUsers: mentionedUsers,
                mentionedAll: hasMentionedAll,
                command: command,
                cooldownTime: cooldownTime
            )
        }

        public mutating func addCommand(_ command: Command) {
            self = .init(
                text: "",
                state: state,
                editingMessage: editingMessage,
                quotingMessage: quotingMessage,
                threadMessage: threadMessage,
                attachments: [],
                mentionedUsers: mentionedUsers,
                mentionedAll: hasMentionedAll,
                command: command,
                cooldownTime: cooldownTime
            )
        }

        public mutating func slowMode(cooldown: Int) {
            self = .init(
                text: text,
                state: state,
                editingMessage: editingMessage,
                quotingMessage: quotingMessage,
                threadMessage: threadMessage,
                attachments: attachments,
                mentionedUsers: mentionedUsers,
                mentionedAll: hasMentionedAll,
                command: command,
                cooldownTime: cooldown
            )
        }

        public mutating func resetSlowMode() {
            self = .init(
                text: text,
                state: state,
                editingMessage: editingMessage,
                quotingMessage: quotingMessage,
                threadMessage: threadMessage,
                attachments: attachments,
                mentionedUsers: mentionedUsers,
                mentionedAll: hasMentionedAll,
                command: command,
                cooldownTime: 0
            )
        }

        public mutating func recording() {
            self = .init(
                text: text,
                state: .recording,
                editingMessage: editingMessage,
                quotingMessage: quotingMessage,
                threadMessage: threadMessage,
                attachments: attachments,
                mentionedUsers: mentionedUsers,
                mentionedAll: hasMentionedAll,
                command: command
            )
        }

        public mutating func recordingLocked() {
            self = .init(
                text: text,
                state: .recordingLocked,
                editingMessage: editingMessage,
                quotingMessage: quotingMessage,
                threadMessage: threadMessage,
                attachments: attachments,
                mentionedUsers: mentionedUsers,
                mentionedAll: hasMentionedAll,
                command: command
            )
        }
    }

    /// The content of the composer.
    public var content: Content = .initial() {
        didSet {
            updateContentIfNeeded()
        }
    }

    private var textChangeRange: NSRange = .init(location: 0, length: 0)
    private var previousText: String = ""
    // Mention index info to calculate between content.text and textView.text
    var mentionIndex: MentionsIndex?

    /// The component responsible for tracking cooldown timing when slow mode is enabled.
    open var cooldownTracker: CooldownTracker = CooldownTracker(timer: ScheduledErmisTimer(interval: 1))

    /// The debouncer to control user searching requests when mentioning users.
    public var userMentionsDebouncer = Debouncer(0.25, queue: .main)

    lazy var linkDetector = TextLinkDetector()

    /// A symbol that is used to recognise when the user is mentioning a user.
    open var mentionSymbol = "@"

    /// A symbol that is used to recognise when the user is typing a command.
    open var commandSymbol = "/"

    /// A Boolean value indicating whether the commands are enabled.
    open var isCommandsEnabled: Bool {
        channelConfig?.commands.isEmpty == false
    }

    /// A Boolean value indicating whether the user mentions are enabled.
    open var isMentionsEnabled: Bool {
        true
    }

    /// A Boolean value indicating whether the attachments are enabled.
    open var isAttachmentsEnabled: Bool {
        channelController?.channel?.canUploadFile ?? true
    }

    /// A Boolean value indicating whether sending message is enabled.
    open var isSendMessageEnabled: Bool {
        channelController?.channel?.canSendMessage ?? true
    }

    /// A Boolean value indicating whether if the message can contain links.
    open var canSendLinks: Bool {
        channelController?.channel?.canSendLink ?? true
    }

    /// A Boolean value indicating whether the current input text contains links.
    open var inputContainsLinks: Bool {
        linkDetector.hasLinks(in: content.text)
    }

    /// A Boolean value indicating whether the current input text contains filter words.
    open var inputContainsFilterKeyword: Bool {
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let filterWords = channelController?.channel?.filterWords,
           filterWords.contains(where: { text.lowercased().contains($0) }) {
            return true
        }
        return false
    }

    /// A Boolean value indicating whether the slowmode should enable.
    open var isSlowModeOn: Bool {
        channelController?.channel?.membership?.memberRole == .member && content.isSlowModeOn
    }

    /// When enabled mentions search users across the entire app instead of searching
    open private(set) lazy var mentionAllAppUsers: Bool = components.mentionAllAppUsers

    /// A controller to search users and that is used to populate the mention suggestions.
    open var userSearchController: UserSearchController!

    /// A controller to search members in a channel and that is used to populate the mention suggestions.
    open var memberListController: ChannelMemberListController?

    /// A controller that manages the channel that the composer is creating content for.
    open var channelController: ChannelController?

    /// The channel config. If it's a new channel, an empty config should be created. (Not yet supported right now)
    public var channelConfig: ChannelConfig? {
        channelController?.channel?.config ?? ChannelConfig()
    }

    var shouldAutoUpdateTextViewContent: Bool = true
    /// The boolean true if we want to prevent handle textview text did changed.
    var preventHandleTextChanged: Bool = false

    /// The component responsible for mention suggestions.
    open lazy var mentionSuggester = TypingSuggester(
        options: TypingSuggestionOptions(
            symbol: mentionSymbol
        )
    )

    /// The component responsible for autocomplete command suggestions.
    open lazy var commandSuggester = TypingSuggester(
        options: TypingSuggestionOptions(
            symbol: commandSymbol,
            shouldTriggerOnlyAtStart: true
        )
    )

    /// The view controller responsible to managing the VoiceRecording flow.
    open internal(set) lazy var voiceRecordingVC = components
        .voiceRecordingViewController
        .init(composerView: composerView)

    /// The audioPlayer that will be used for the VoiceRecording's playback.
    open var audioPlayer: AudioPlaying? {
        didSet {
            // When the audioPlayer changes to a new instance, forward it to
            // the attachmentsVC and voiceRecordingVC to ensure that all are using
            // the same one.
            attachmentsVC.audioPlayer = audioPlayer
            voiceRecordingVC.audioPlayer = audioPlayer
        }
    }

    open private(set) lazy var composerView: ComposerView = components
        .messageComposerView.init()
        .withoutAutoresizingMaskConstraints

    /// The view that show to hidden `composerView`, for ex: when user is Banned...
    open private(set) lazy var composerDisableView: UIView = UIView()
        .withoutAutoresizingMaskConstraints

    open private(set) lazy var composerBlockedView = components
        .messageComposerBlockedView.init()
        .withoutAutoresizingMaskConstraints

    open private(set) lazy var composerBannedView: UIView = components
        .messageComposerBannedView.init()
        .withoutAutoresizingMaskConstraints

    open private(set) lazy var composerGuestView = components
        .messageComposerGuestView.init()
        .withoutAutoresizingMaskConstraints

    /// The view controller that shows the suggestions when the user is typing.
    open private(set) lazy var suggestionsVC: SuggestionsViewController = components
        .suggestionsVC
        .init()

    /// The view controller that shows the suggestions when the user is typing.
    open private(set) lazy var attachmentsVC: AttachmentsPreviewViewController = components
        .messageComposerAttachmentsVC
        .init()

    open private(set) lazy var alertRouter: AlertsRouter = {
        if let channelVC = parent as? ChannelViewController {
            components.alertsRouter.init(rootViewController: channelVC.messageListVC)
        } else {
            components.alertsRouter.init(rootViewController: self)
        }
    }()

    /// The view controller for selecting image attachments.
    open private(set) lazy var mediaPickerVC: UIViewController = {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.view.tintColor = theme.colors.primary
        picker.delegate = self
        return picker
    }()

    /// The View Controller for taking a picture.
    open private(set) lazy var cameraVC: UIViewController = {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.modalPresentationStyle = .overFullScreen
        camera.mediaTypes = UIImagePickerController.availableMediaTypes(for: .camera) ?? ["public.image"]
        camera.delegate = self
        return camera
    }()

    /// The view controller for selecting file attachments.
    open private(set) lazy var filePickerVC: UIViewController = {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        return picker
    }()

    override open func setUp() {
        super.setUp()

        composerView.inputMessageView.textView.delegate = self

        // Set the delegate for handling the pasting of UIImages in the text view
        composerView.inputMessageView.textView.clipboardAttachmentDelegate = self

        composerView.sendButton.addTarget(self, action: #selector(publishMessage), for: .touchUpInside)
        composerView.confirmButton.addTarget(self, action: #selector(publishMessage), for: .touchUpInside)
        composerView.photoButton.addTarget(self, action: #selector(showPhotoPicker), for: .touchUpInside)
        composerView.stickerButton.addTarget(self, action: #selector(showStickerPicker), for: .touchUpInside)
        composerView.commandsButton.addTarget(self, action: #selector(showAvailableCommands), for: .touchUpInside)
        composerView.dismissButton.addTarget(self, action: #selector(clearContent(sender:)), for: .touchUpInside)
        composerView.composerMenuButton.onMenuItemDidTapped = { [weak self] item in
            self?.onMenuButtonDidSelected(item: item)
        }
        composerView.inputMessageView.clearButton.addTarget(
            self,
            action: #selector(clearContent(sender:)),
            for: .touchUpInside
        )

        channelController?.delegate = self

        setupAttachmentsView()
        setupVoiceRecordingView()

        cooldownTracker.onChange = { [weak self] currentTime in
            guard currentTime != 0 && self?.content.state != .edit else {
                self?.content.resetSlowMode()
                return
            }

            self?.content.slowMode(cooldown: currentTime)
        }

        composerView.inputMessageView.textView.onLinksChanged = { [weak self] links in
            self?.didChangeLinks(links)
        }
        composerView.linkPreviewView.onClose = { [weak self] in
            self?.dismissLinkPreview()
        }
    }

    override open func setUpUI() {
        super.setUpUI()

        view.addSubview(composerView)
        view.addSubview(composerDisableView)
        composerView.pin(to: view)
        composerDisableView.pin(anchors: [.top, .leading, .trailing],to: view)
        composerDisableView.pin(anchors: [.bottom], to: view.safeAreaLayoutGuide)
    }

    open func setupAttachmentsView() {
        addChildViewController(attachmentsVC, embedIn: composerView.inputMessageView.attachmentsViewContainer)
        attachmentsVC.didTapRemoveItemButton = { [weak self] index in
            self?.content.attachments.remove(at: index)
        }
    }

    open func setupVoiceRecordingView() {
        voiceRecordingVC.delegate = self
        addChild(voiceRecordingVC)
        voiceRecordingVC.didMove(toParent: self)
        voiceRecordingVC.setUp()
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        resumeCurrentCooldown()
    }

    override open func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateUnsentContent()
        dismissSuggestions()
    }

    // MARK: Update Content

    override open func contentDidChanged() {
        super.contentDidChanged()

        // Note: The order of the calls is important.
        updateText()
        updateKeystrokeEvents()
        updateTitleLabel()
        updateCommandsButtonVisibility()
        updateConfirmButtonVisibility()
        updateSendButtonVisibility()
        updatePhotoButtonVisibility()
        updateStickerButtonVisibility()
        updateHeaderViewVisibility()
        updateRecordButtonVisibility()
        updateCooldownView()
        updateCooldownViewVisibility()
        updateSendButtonEnabled()
        updateConfirmButtonEnabled()
        updateInputMessageView()
        updateInputMessageViewVisibility()
        updateInputAttachmentsView()
        updateLinkPreview()
        updateBottomContainerVisibility()
        updateLeadingContainerVisibility()
        updateCommandSuggestions()
        updateMentionSuggestions()
        updatePlaceholderLabel()
        updateComposerDisableView()
    }

    open func updateText() {
        guard shouldAutoUpdateTextViewContent else {
            return
        }
        var displayText = content.text

        guard !content.mentionedUsers.isEmpty else {
            if composerView.inputMessageView.textView.text != displayText {
                // Updating the text unnecessarily makes the caret jump to the end of input
                preventHandleTextChanged = true
                composerView.inputMessageView.textView.text = displayText
                preventHandleTextChanged = false
            }
            return
        }

        for mentionUser in content.mentionedUsers {
            let mentionString = mentionUser.mentionString
            let mentionDisplayString = mentionUser.mentionsDisplayString
            guard mentionString != mentionDisplayString else {
                continue
            }
            let ranges = displayText.ranges(of: mentionString)
            for range in ranges.reversed() {
                displayText = displayText.replacingCharacters(in: range, with: mentionDisplayString)
            }
        }

        if composerView.inputMessageView.textView.text != displayText {
            // Updating the text unnecessarily makes the caret jump to the end of input
            preventHandleTextChanged = true
            composerView.inputMessageView.textView.text = displayText
            preventHandleTextChanged = false
        }
    }

    open func updateKeystrokeEvents() {
        if !content.isEmpty && channelConfig?.typingEventsEnabled == true,
           UIApplication.shared.applicationState == .active {
            channelController?.sendKeystrokeEvent(parentMessageId: content.threadMessage?.id)
        }
    }

    open func updateMenuButtonVisibility() {
        let textView = composerView.inputMessageView.textView
        Animate {
            let leadingViews = self.composerView.leadingContainer.subviews
            let isNotShrinkInputButton: (UIView) -> Bool = { $0 !== self.composerView.composerMenuButton }
            let isLeadingActionsVisible = leadingViews
                .filter { isNotShrinkInputButton($0) && self.composerView.composerMenuButton.isHidden }
                .filter(\.isHidden).isEmpty
            self.composerView.composerMenuButton.isHidden = self.content.isVoiceRecording //textView.text.isEmpty || self.content .hasCommand || !isLeadingActionsVisible
        }
    }

    open func updateRecordButtonVisibility() {
        guard isSendMessageEnabled else {
            composerView.recordButton.isHidden = true
            return
        }

        let isSendButtonHidden = composerView.sendButton.isHidden
        let isConfirmButtonHidden = composerView.confirmButton.isHidden
        let isVoiceRecordingEnabled = components.isVoiceRecordingEnabled
        Animate {
            switch self.content.state {
            case .new:
                self.composerView.recordButton.isHidden = !isSendButtonHidden || !isVoiceRecordingEnabled || !self.isAttachmentsEnabled
            case .recording:
                self.composerView.recordButton.isHidden = false
            case .recordingLocked:
                self.composerView.recordButton.isHidden = true
            case .quote:
                self.composerView.recordButton.isHidden = !isSendButtonHidden || !isVoiceRecordingEnabled || !self.isAttachmentsEnabled
            case .edit:
                self.composerView.recordButton.isHidden = isConfirmButtonHidden || !self.isAttachmentsEnabled
            default:
                break
            }
        }
    }

    open func updateTitleLabel() {
        switch content.state {
        case .edit:
            composerView.titleLabel.text = L10n.Composer.Title.edit
        case .quote:
            composerView.titleLabel.text = L10n.Composer.Title.reply
        default:
            break
        }
    }

    open func updateCooldownView() {
        composerView.cooldownView.content = .init(cooldown: content.cooldownTime)
    }

    open func updateCooldownViewVisibility() {
        Animate {
            switch self.content.state {
            case .new, .quote:
                self.composerView.cooldownView.isHidden = !self.isSlowModeOn
            case .edit, .recording, .recordingLocked:
                self.composerView.cooldownView.isHidden = true
            default:
                break
            }
        }
    }

    open func updateSendButtonEnabled() {
        composerView.sendButton.isEnabled = (!content.isEmpty) &&
        !self.inputContainsFilterKeyword &&
        (self.canSendLinks || !self.inputContainsLinks)
    }

    open func updateConfirmButtonEnabled() {
        composerView.confirmButton.isEnabled = !content.isEmpty
    }

    open func updatePhotoButtonVisibility() {
        guard isSendMessageEnabled else {
            composerView.photoButton.isHidden = true
            return
        }

        let isPhotoButtonHidden = !isAttachmentsEnabled || content.hasCommand || !content.isEmpty || content.isVoiceRecording
        Animate {
            self.composerView.photoButton.isHidden = isPhotoButtonHidden
        }
    }

    open func updateStickerButtonVisibility() {
        guard isSendMessageEnabled else {
            composerView.stickerButton.isHidden = true
            return
        }

        let isStickerButtonHidden = !isAttachmentsEnabled || content.hasCommand || !content.isEmpty || content.isVoiceRecording
        Animate {
            self.composerView.stickerButton.isHidden = isStickerButtonHidden
        }
    }

    open func updateCommandsButtonVisibility() {
        guard isSendMessageEnabled else {
            composerView.commandsButton.isHidden = true
            return
        }

        let isCommandsButtonHidden = !isCommandsEnabled || content.hasCommand || !composerView.composerMenuButton.isHidden
        Animate {
            self.composerView.commandsButton.isHidden = isCommandsButtonHidden
        }
    }

    open func updateInputMessageView() {
        composerView.inputMessageView.content = .init(
            quotingMessage: content.quotingMessage,
            command: content.command,
            channel: channelController?.channel
        )
        composerView.inputMessageView.isUserInteractionEnabled = isSendMessageEnabled
    }

    open func updateInputMessageViewVisibility() {
        Animate {
            self.composerView.inputMessageView.isHidden = self.content.isVoiceRecording
        }
    }

    open func updateInputAttachmentsView() {
        attachmentsVC.content = content.attachments.map {
            if let provider = $0.payload as? AttachmentPreviewProvider {
                return provider
            } else {
                log.warning("""
                Attachment \($0) doesn't conform to the `AttachmentPreviewProvider` protocol. Add the conformance \
                to this protocol to avoid using the attachment preview placeholder in the composer.
                """)
                return DefaultAttachmentPreviewProvider()
            }
        }
        composerView.inputMessageView.attachmentsViewContainer.isHidden = content.attachments.isEmpty
    }

    open func updateLinkPreview() {
        // Since we don't want to show link previews with other attachment types, we dismiss the
        // link preview in case it is being shown and there are other types of attachments in the message.
        if content.hasOnlyLinkAttachments == false {
            dismissLinkPreview()
        }
    }

    open func updateBottomContainerVisibility() {
        Animate {
            self.composerView.bottomContainer.isHidden = !self.content.isInsideThread
        }
    }

    open func updateLeadingContainerVisibility() {
        Animate {
            self.composerView.leadingContainer.isHidden = self.content.isVoiceRecording
        }
    }

    open func updateCommandSuggestions() {
        if isCommandsEnabled, let typingCommand = typingCommand(in: composerView.inputMessageView.textView) {
            showCommandSuggestions(for: typingCommand)
            return
        }
    }

    open func updateMentionSuggestions() {
        if isMentionsEnabled,
           channelController?.channel?.isDirectMessageChannel == false,
           let (typingMention, mentionRange) = typingMention(in: composerView.inputMessageView.textView) {
            userMentionsDebouncer.execute { [weak self] in
                self?.showMentionSuggestions(for: typingMention, mentionRange: mentionRange)
            }
            return
        } else {
            userMentionsDebouncer.execute { [weak self] in
                self?.dismissSuggestions()
            }
        }
    }

    open func updatePlaceholderLabel() {
        guard isSendMessageEnabled else {
            composerView.inputMessageView.textView.placeholderLabel.text = L10n.Composer.Placeholder.messageDisabled
            return
        }

        composerView.inputMessageView.textView.placeholderLabel.text = isSlowModeOn
        ? L10n.Composer.Placeholder.slowMode
        : L10n.Composer.Placeholder.message
    }

    open func updateConfirmButtonVisibility() {
        guard isSendMessageEnabled else {
            composerView.confirmButton.isHidden = true
            return
        }

        Animate {
            self.composerView.confirmButton.isHidden = self.content.state != .edit
        }
    }

    open func updateSendButtonVisibility() {
        Animate {
            switch self.content.state {
            case .new, .quote:
                self.composerView.sendButton.isHidden = self.isSlowModeOn || self.content.isEmpty
            case .edit, .recording, .recordingLocked:
                self.composerView.sendButton.isHidden = true
            default:
                break
            }
        }
    }

    open func updateHeaderViewVisibility() {
        Animate {
            switch self.content.state {
            case .new, .recording:
                self.composerView.headerView.isHidden = true
            case .edit, .quote, .recordingLocked:
                self.composerView.headerView.isHidden = false
            default:
                break
            }
        }
    }

    open func updateComposerDisableView() {
        let isBanned = channelController?.channel?.membership?.isBannedFromChannel == true
        let isBlocked = channelController?.channel?.isBlocked == true
        let isGuest = channelController?.channel?.isGuess == true
        let isDirectChannel = channelController?.channel?.isDirectMessageChannel == true
        let isDisableComposer = isBanned || (isBlocked && isDirectChannel) || isGuest

        if isBlocked {
            let directUserName = channelController?.channel?.directUserMembership?.displayName ?? ""
            if let composerBlockedView = composerDisableView.subviews.first as? ComposerBlockedView {
                composerBlockedView.content = directUserName
            } else {
                composerDisableView.subviews.forEach { $0.removeFromSuperview() }
                composerDisableView.embed(composerBlockedView)
                composerBlockedView.content = directUserName
                composerBlockedView.delegate = self
            }

        } else if isBanned {
            if composerDisableView.subviews.first as? ComposerBannedView == nil {
                composerDisableView.subviews.forEach { $0.removeFromSuperview() }
                composerDisableView.embed(composerBannedView)
            }
        } else if isGuest {
            if composerDisableView.subviews.first as? ComposerGuestView == nil {
                composerDisableView.subviews.forEach { $0.removeFromSuperview() }
                composerDisableView.embed(composerGuestView)
                composerGuestView.delegate = self
            }
        }

        composerDisableView.isHidden = !isDisableComposer
    }

    // MARK: - Actions

    @objc open func publishMessage(sender: UIButton) {
        if !canSendLinks, inputContainsLinks {
            presentAlert(title: L10n.Composer.LinksDisabled.title,
                         message: L10n.Composer.LinksDisabled.subtitle)
            return
        }

        let text: String
        if let command = content.command {
            text = "/\(command.name) " + content.text
        } else {
            if inputContainsFilterKeyword {
                presentAlert(title: L10n.Composer.Filterwords.contentContainBlockedKeywords)
                return
            }
            text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let editingMessage = content.editingMessage {
            editMessage(withId: editingMessage.id, newText: text)
            channelController?.sendStopTypingEvent()
            content.clear()
            channelController?.saveComposerUnsentContent(nil)
        } else {
            createNewMessage(text: text)

            let channel = channelController?.channel
            if !content.hasCommand, let cooldownDuration = channel?.cooldownDuration {
                cooldownTracker.start(with: cooldownDuration)
            }
            content.clear()
            channelController?.saveComposerUnsentContent(nil)
        }
    }

    /// Shows a photo/media picker.
    open func showMediaPicker() {
        present(mediaPickerVC, animated: true)
    }

    /// Shows a document picker.
    @objc open func showFilePicker() {
        present(filePickerVC, animated: true)
    }

    open func showCamera() {
        present(cameraVC, animated: true)
    }

    /// Returns actions for attachments picker.
    open var photosPickerActions: [UIAlertAction] {
        let showMediaPickerAction = UIAlertAction(
            title: L10n.Composer.Picker.media,
            style: .default,
            handler: { [weak self] _ in self?.showMediaPicker() }
        )

        let showCameraAction = UIAlertAction(
            title: L10n.Composer.Picker.camera,
            style: .default,
            handler: { [weak self] _ in self?.showCamera() }
        )

        let cancelAction = UIAlertAction(
            title: L10n.Composer.Picker.cancel,
            style: .cancel
        )

        let isCameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

        if isCameraAvailable {
            return [showCameraAction, showMediaPickerAction, cancelAction]
        }

        return [showMediaPickerAction, cancelAction]
    }

    open func onMenuButtonDidSelected(item: ComposerMenuItemType) {
        switch item {
        case .location:
            presentAlert(message: "Feature under develop")
        case .file:
            showFilePicker()
        case .poll:
            presentAlert(message: "Feature under develop")
        case .custom(let string):
            // Implement in subclass if want to add custom type button.
            break
        }
    }

    @objc open func showAvailableCommands(sender: UIButton) {
        if suggestionsVC.isPresented {
            dismissSuggestions()
        } else {
            showCommandSuggestions(for: "")
        }
    }

    @objc open func showPhotoPicker(sender: UIButton) {
        let isCameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        if isCameraAvailable {
            presentAlert(
                message: L10n.Composer.Picker.photoTitle,
                preferredStyle: .actionSheet,
                actions: photosPickerActions,
                sourceView: sender
            )
        } else {
            self.showMediaPicker()
        }
    }

    @objc open func showStickerPicker(sender: UIButton) {
        presentAlert(message: "Feature under develop")
    }

    @objc open func clearContent(sender: UIButton) {
        content.clear()
    }

    /// Creates a new message and notifies the delegate that a new message was created.
    /// - Parameter text: The text content of the message.
    open func createNewMessage(text: String) {
        guard let cid = channelController?.cid else { return }

        // If the user included some mentions via suggestions,
        // but then removed them from text, we should remove them from
        // the content we'll send
        for user in content.mentionedUsers {
            if !text.contains(user.mentionString) {
                content.mentionedUsers.remove(user)
            }
        }

        if !text.contains("@all") {
            content.hasMentionedAll = false
        }

        if let threadParentMessageId = content.threadMessage?.id {
            let messageController = channelController?.client.messageController(
                cid: cid,
                messageId: threadParentMessageId
            )

            messageController?.createNewReply(
                text: text,
                attachments: content.attachments,
                mentionedUserIds: content.mentionedUsers.map(\.userId),
                mentionedAll: content.hasMentionedAll,
                quotedMessageId: content.quotingMessage?.id
            )
            return
        }

        channelController?.createNewMessage(
            text: text,
            attachments: content.attachments,
            mentionedUserIds: content.mentionedUsers.map(\.userId),
            mentionedAll: content.hasMentionedAll,
            quotedMessageId: content.quotingMessage?.id
        )
    }

    /// Updates an existing message.
    /// - Parameters:
    ///   - id: The id of the editing message.
    ///   - newText: The new text content of the message.
    open func editMessage(withId id: MessageId, newText: String) {
        guard let cid = channelController?.cid else { return }
        let messageController = channelController?.client.messageController(
            cid: cid,
            messageId: id
        )
        // TODO: Adjust LLC to edit mentions
        messageController?.editMessage(
            text: newText,
            attachments: content.attachments
        )
    }

    /// Returns a potential user mention in case the user is currently typing a username.
    /// - Parameter textView: The text view of the message input view where the user is typing.
    /// - Returns: A tuple with the potential user mention and the position of the mention so it can be autocompleted.
    open func typingMention(in textView: UITextView) -> (String, NSRange)? {
        guard let typingSuggestion = mentionSuggester.typingSuggestion(in: textView) else {
            return nil
        }

        return (typingSuggestion.text, typingSuggestion.locationRange)
    }

    /// Returns a potential command in case the user is currently typing a command.
    /// - Parameter textView: The text view of the message input view where the user is typing.
    /// - Returns: A string of the corresponding potential command.
    open func typingCommand(in textView: UITextView) -> String? {
        let typingSuggestion = commandSuggester.typingSuggestion(in: textView)
        return typingSuggestion?.text
    }

    /// Shows the command suggestions for the potential command the current user is typing.
    /// - Parameter typingCommand: The potential command that the current user is typing.
    open func showCommandSuggestions(for typingCommand: String) {
        let availableCommands = channelController?.channel?.config?.commands ?? []

        // Don't show the commands suggestion VC if there are no commands
        guard availableCommands.isEmpty == false else { return }

        var commandHints: [Command] = availableCommands

        if !typingCommand.isEmpty {
            commandHints = availableCommands.filter {
                $0.name.range(of: typingCommand, options: .caseInsensitive) != nil
            }
        }

        let typingCommandMatches: ((Command) -> Bool) = { availableCommand in
            availableCommand.name.compare(typingCommand, options: .caseInsensitive) == .orderedSame
        }
        if let foundCommand = availableCommands.first(where: typingCommandMatches), !content.hasCommand {
            content.addCommand(foundCommand)

            dismissSuggestions()
            return
        }

        let dataSource = MessageComposerSuggestionsCommandDataSource(
            with: commandHints,
            collectionView: suggestionsVC.collectionView
        )
        suggestionsVC.dataSource = dataSource
        suggestionsVC.didSelectItemAt = { [weak self] commandIndex in
            guard let hintCommand = commandHints[safe: commandIndex] else {
                indexNotFoundAssertion()
                return
            }

            self?.content.addCommand(hintCommand)

            self?.dismissSuggestions()
        }

        showSuggestions()
    }

    /// Returns the query to be used for searching users across the whole app.
    ///
    /// This function is called in `showMentionSuggestions` to retrieve the query
    /// that will be used to search the users. You should override this if you want to change the
    /// user searching logic.
    ///
    /// - Parameter typingMention: The potential user mention the current user is typing.
    /// - Returns: `UserListQuery` instance that will be used for searching users.
    open func queryForMentionSuggestionsSearch(typingMention term: String) -> UserListQuery {
        UserListQuery(
            filter: .or([
                .autocomplete(.name, text: term),
                .autocomplete(.id, text: term)
            ]),
            sort: [.init(key: .name, isAscending: true)],
            projectId: channelController?.cid?.projectId
        )
    }

    /// Returns the query to be used for searching members inside a channel.
    ///
    /// This function is called in `showMentionSuggestions` to retrieve the query
    /// that will be used to search for members. You should override this if you want to change the
    /// member searching logic.
    ///
    /// - Parameter typingMention: The potential user mention the current user is typing.
    /// - Returns: `ChannelMemberListQuery` instance that will be used for searching members in a channel.
    open func queryForChannelMentionSuggestionsSearch(typingMention term: String) -> ChannelMemberListQuery? {
        guard let cid = channelController?.cid else {
            return nil
        }
        return ChannelMemberListQuery(
            cid: cid,
            filter: .autocomplete(.name, text: term),
            sort: [.init(key: .name, isAscending: true)]
        )
    }

    /// Returns the member list controller to be used for searching members inside a channel.
    ///
    /// - Parameter term: The potential user mention the current user is typing.
    /// - Returns: `ChannelMemberListController` instance that will be used for searching members in a channel.
    open func makeMemberListControllerForMemberSuggestions(typingMention term: String) -> ChannelMemberListController? {
        guard let query = queryForChannelMentionSuggestionsSearch(typingMention: term) else { return nil }
        return userSearchController.client.memberListController(query: query)
    }

    /// Shows the mention suggestions for the potential mention the current user is typing.
    /// - Parameters:
    ///   - typingMention: The potential user mention the current user is typing.
    ///   - mentionRange: The position where the current user is typing a mention to it can be replaced with the suggestion.
    open func showMentionSuggestions(for typingMention: String, mentionRange: NSRange) {
        guard !content.text.isEmpty else {
            // Because we do not have cancellation, when a mention request is finished it can happen
            // that we already published the message, so we don't need to show the suggestions anymore.
            return
        }
        guard let dataSource = makeMentionSuggestionsDataSource(for: typingMention) else {
            return
        }
        suggestionsVC.dataSource = dataSource
        suggestionsVC.didSelectItemAt = { [weak self] userIndex in
            guard let self = self else { return }

            var mentionObject: MentionSuggestionView.Content
            if dataSource.mentionedAll, userIndex == 0 {
                mentionObject = .allUser
            } else {
                guard let user = dataSource.mentionedAll ? dataSource.users[safe: userIndex - 1] : dataSource.users[safe: userIndex] else {
                    indexNotFoundAssertion()
                    return
                }
                mentionObject = .mention(user)
            }
            insertMentionObject(mentionObject, at: mentionRange, typingMention: typingMention)
        }

        showSuggestions()
    }

    /// Creates a `MessageComposerSuggestionsMentionDataSource` with data from local cache, user search or channel members.
    /// The source of the data will depend on `mentionAllAppUsers` flag and the amount of members in the channel.
    /// - Parameter typingMention: The potential user mention the current user is typing.
    /// - Returns: A `MessageComposerSuggestionsMentionDataSource` instance.
    public func makeMentionSuggestionsDataSource(for typingMention: String) -> MessageComposerSuggestionsMentionDataSource? {
        guard let channel = channelController?.channel else {
            return nil
        }

        guard let currentUserId = channelController?.client.currentUserId else {
            return nil
        }

        let trimmedTypingMention = typingMention.trimmingCharacters(in: .whitespacesAndNewlines)
        let mentionedUsersNames = content.mentionedUsers.map(\.name)
        let mentionedUsersIds = content.mentionedUsers.map(\.userId)
        let mentionIsAlreadyPresent = mentionedUsersNames.contains(trimmedTypingMention) || mentionedUsersIds.contains(trimmedTypingMention)
        let shouldShowEmptyMentions = typingMention.isEmpty || mentionIsAlreadyPresent

        // Because we re-create the MessageComposerSuggestionsMentionDataSource always from scratch
        // We lose the results of the previous search query, so we need to provide it manually.
        let initialUsers: (String, [ChatUser]) -> [ChatUser] = { previousQuery, previousResult in
            if typingMention.isEmpty {
                return []
            }
            if typingMention.hasPrefix(previousQuery) || previousQuery.hasPrefix(typingMention) {
                return previousResult
            }
            return []
        }

        if mentionAllAppUsers {
            var previousResult = userSearchController.users
            let previousQuery = (userSearchController?.query?.filter?.value as? String) ?? ""
            if shouldShowEmptyMentions {
                userSearchController.clearResults()
                previousResult = []
            } else {
                userSearchController.search(
                    query: queryForMentionSuggestionsSearch(typingMention: typingMention)
                )
            }
            return MessageComposerSuggestionsMentionDataSource(
                collectionView: suggestionsVC.collectionView,
                searchController: userSearchController,
                memberListController: nil,
                initialUsers: initialUsers(previousQuery, previousResult),
                isMentionedAll: typingMention.isEmpty
            )
        }

        let memberCount = channel.memberCount
        if memberCount > channel.lastActiveMembers.count {
            var previousResult = Array(memberListController?.members ?? [])
            let previousQuery = (memberListController?.query.filter?.value as? String) ?? ""
            memberListController = makeMemberListControllerForMemberSuggestions(typingMention: typingMention)
            if shouldShowEmptyMentions {
                memberListController = nil
                previousResult = []
            } else {
                memberListController?.synchronize()
            }
            return MessageComposerSuggestionsMentionDataSource(
                collectionView: suggestionsVC.collectionView,
                searchController: userSearchController,
                memberListController: memberListController,
                initialUsers: initialUsers(previousQuery, previousResult),
                isMentionedAll: typingMention.isEmpty
            )
        }

        let usersCache = searchUsers(
            channel.lastActiveMembers.filter({ $0.memberRole != .pending && !$0.isBannedFromChannel && $0.userId != currentUserId}),
            by: typingMention,
            excludingId: currentUserId
        )
        return MessageComposerSuggestionsMentionDataSource(
            collectionView: suggestionsVC.collectionView,
            searchController: userSearchController,
            memberListController: nil,
            initialUsers: usersCache,
            isMentionedAll: typingMention.isEmpty
        )
    }

    /// Shows the suggestions view
    open func showSuggestions() {
        if !suggestionsVC.isPresented, let parent = parent {
            parent.addChildViewController(suggestionsVC, targetView: parent.view)

            let suggestionsView = suggestionsVC.view!
            suggestionsView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                suggestionsView.leadingAnchor.pin(equalTo: parent.view.leadingAnchor),
                suggestionsView.trailingAnchor.pin(equalTo: parent.view.trailingAnchor),
                composerView.topAnchor.pin(equalToSystemSpacingBelow: suggestionsView.bottomAnchor),
                suggestionsView.topAnchor.pin(greaterThanOrEqualTo: parent.view.safeAreaLayoutGuide.topAnchor)
            ])
        }
    }

    /// Dismisses the suggestions view.
    open func dismissSuggestions() {
        suggestionsVC.removeFromParent()
        suggestionsVC.view.removeFromSuperview()
    }

    /// The links in the current input text have changed
    /// - Parameter links: The new parsed links from the input text.
    open func didChangeLinks(_ links: [TextLink]) {
        guard channelConfig?.urlEnrichmentEnabled == true else {
            return
        }

        // We only show the link preview if there no other types of attachments.
        guard content.hasOnlyLinkAttachments else {
            dismissLinkPreview()
            return
        }

        /// We only try to display the link preview of the first link.
        guard let link = links.first else {
            dismissLinkPreview()
            return
        }
    }

    /// Shows the link preview view.
    open func showLinkPreview(for linkPayload: LinkAttachmentPayload) {
        Animate {
            self.composerView.linkPreviewView.isHidden = false
            self.composerView.linkPreviewView.content = .init(linkAttachmentPayload: linkPayload)
        }
    }

    /// Dismisses the link preview view.
    open func dismissLinkPreview() {
        Animate {
            self.composerView.linkPreviewView.isHidden = true
            self.composerView.linkPreviewView.content = nil
        }
    }

    /// Creates and adds an attachment from the given URL to the `content`
    /// - Parameters:
    ///   - url: The URL of the attachment
    ///   - type: The type of the attachment
    open func addAttachmentToContent(
        from url: URL,
        type: AttachmentType
    ) throws {
        try addAttachmentToContent(from: url, type: type, info: [:])
    }

    /// Creates and adds an attachment from the given URL to the `content`
    /// - Parameters:
    ///   - url: The URL of the attachment
    ///   - type: The type of the attachment
    ///   - info: The metadata of the attachment
    open func addAttachmentToContent(
        from url: URL,
        type: AttachmentType,
        info: [LocalAttachmentInfoKey: Any]
    ) throws {
        guard let chatConfig = channelController?.client.config else {
            log.assertionFailure("Channel controller must be set at this point")
            return
        }

        let fileSize = try AttachmentFile(url: url).size

        let maxAttachmentSize = maxAttachmentSize(for: type)
        guard fileSize <= maxAttachmentSize else {
            throw AttachmentValidationError.maxFileSizeExceeded
        }

        var localMetadata = AnyAttachmentLocalMetadata()
        localMetadata.fileSize = Int(fileSize)
        if let image = info[.originalImage] as? UIImage {
            localMetadata.originalResolution = (
                width: Double(image.size.width),
                height: Double(image.size.height)
            )
        }

        switch type {
        case .voiceRecording:
            localMetadata.duration = info[.duration] as? TimeInterval
            localMetadata.waveformData = info[.waveformData] as? [Float]
        default:
            /* No-op */
            break
        }

        let attachment = try AnyAttachmentPayload(
            localFileURL: url,
            attachmentType: type,
            localMetadata: localMetadata
        )
        content.attachments.append(attachment)
    }

    /// The maximum upload file size depending on the attachment type.
    ///
    /// The max attachment size can be set from the Ermis's Dashboard App Settings.
    /// - Parameter attachmentType: The attachment type that is being uploaded.
    /// - Returns: The file size limit in bytes. The default value is 200MB.
    open func maxAttachmentSize(for attachmentType: AttachmentType) -> Int64 {
        AttachmentValidationError.fileSizeMaxLimitFallback
        guard let client = channelController?.client else {
            log.assertionFailure("Channel controller must be set at this point")
            return AttachmentValidationError.fileSizeMaxLimitFallback
        }

        return client.config.maxAttachmentSize
    }

    /// Shows an alert for the error thrown when adding attachment to a composer.
    /// - Parameters:
    ///   - attachmentURL: The attachment's file URL.
    ///   - attachmentType: The type of attachment.
    ///   - error: The thrown error.
    open func handleAddAttachmentError(
        attachmentURL: URL,
        attachmentType: AttachmentType,
        error: Error
    ) {
        switch error {
        case AttachmentValidationError.maxFileSizeExceeded:
            showAttachmentExceedsMaxSizeAlert()
        default:
            log.assertionFailure(error.localizedDescription)
        }
    }

    /// Resumes the cooldown if the channel has currently an active cooldown.
    public func resumeCurrentCooldown() {
        if let currentCooldownTime = channelController?.currentCooldownTime() {
            cooldownTracker.start(with: currentCooldownTime)
        }
    }

    public func resumeUnsentContent(_ unsentContent: ComposerContent) {
        self.preventHandleTextChanged = true
        self.previousText = unsentContent.previousText
        self.composerView.inputMessageView.textView.text = unsentContent.textViewText

        self.content = .init(with: unsentContent)
        self.textViewDidChange(self.composerView.inputMessageView.textView)
        self.preventHandleTextChanged = false
    }

    public func textContentDidChanged() {
        if self.inputContainsFilterKeyword {
            alertRouter.showInputTextContaintFilterWordAlert()
        } else if !self.canSendLinks, self.inputContainsLinks {
            alertRouter.showCanNotSendLinkAlert()
        }
    }

    public func updateUnsentContent() {
        if content.text.isEmpty || content.isVoiceRecording {
            channelController?.saveComposerUnsentContent(nil)
        } else {

            let unsentContent = ComposerContent(text: content.text,
                                                previousText: previousText,
                                                textViewText: composerView.inputMessageView.textView.text,
                                                state: content.state.rawValue,
                                                hasMentionAll: content.hasMentionedAll,
                                                mentionUsers: content.mentionedUsers,
                                                quotingMessage: content.quotingMessage,
                                                threadMessage: content.threadMessage,
                                                editingMessage: content.editingMessage,
                                                createdAt: Date())
            channelController?.saveComposerUnsentContent(unsentContent)
        }
    }
    // MARK: - UITextViewDelegate

    open func textViewDidChange(_ textView: UITextView) {
        defer {
            updateMenuButtonVisibility()
        }
        if preventHandleTextChanged {
            return
        }

        preventHandleTextChanged = true
        shouldAutoUpdateTextViewContent = false
        var newText = textView.text ?? ""
        var previousText = self.previousText

        let commonPrefix = newText.commonPrefix(with: previousText)
        newText.removeFirst(commonPrefix.count)
        previousText.removeFirst(commonPrefix.count)

        let commonSuffix = String(String(newText.reversed()).commonPrefix(with: String(previousText.reversed())).reversed())

        var changedText = textView.text ?? ""
        changedText.removeFirst(commonPrefix.count)
        changedText.removeLast(commonSuffix.count)

        let previousChangeTextStartIndex = self.previousText.index(self.previousText.startIndex, offsetBy: commonPrefix.count)
        var previousChangeTextEndIndex = self.previousText.index(self.previousText.endIndex, offsetBy: -commonSuffix.count)

        let previousChangedTextRange = Range(uncheckedBounds: (previousChangeTextStartIndex,
                                                               previousChangeTextEndIndex))
        let nsRange = NSRange(previousChangedTextRange, in: self.previousText)
        self.onTextViewChangeText(textView, currentText: self.previousText, in: nsRange, text: changedText)
        //
        self.textContentDidChanged()
    }

    open func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if preventHandleTextChanged {
            return true
        }
        textChangeRange = range
        previousText = textView.text
        return true
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
    }

    func onTextViewChangeText(_ textView: UITextView, currentText: String, in range: NSRange, text: String) {
        guard var messageTextRange = Range(range, in: currentText) else {
            return
        }

        mentionIndex = calculateMentionIndex(message: currentText)

        guard let mentionIndex = mentionIndex else {
            return
        }

        shouldAutoUpdateTextViewContent = false

        var overlapMessageRanges: [Range<String.Index>] = []
        var overlapMessageRangeIndexs: [Int] = []

        for (index, messageRange) in mentionIndex.messageRanges.enumerated() {
            let nsRange = NSRange(messageRange, in: currentText)
            guard let range = Range(nsRange, in: currentText) else {
                continue
            }
            if range.overlaps(messageTextRange) {
                overlapMessageRanges.append(range)
                overlapMessageRangeIndexs.append(index)
            }
        }
        var replaceText = text
        var updatedText = currentText.replacingCharacters(in: messageTextRange, with: replaceText)

        // Removed mention user if needed
        if !overlapMessageRanges.isEmpty {
            var removedUsers: Set<ChatUser> = []
            let overlapContentRanges = overlapMessageRangeIndexs.map { mentionIndex.contentRanges[$0] }
            for mentionedUser in content.mentionedUsers {
                let mentionString = mentionedUser.mentionString
                let ranges = content.text.ranges(of: mentionString)
                if ranges.allSatisfy({ range in
                    return overlapContentRanges.contains { overlapContentRange in
                        overlapContentRange.contains(range.lowerBound) && overlapContentRange.contains(range.upperBound)
                    }
                }) {
                    removedUsers.insert(mentionedUser)
                }
            }
            content.mentionedUsers = content.mentionedUsers.subtracting(removedUsers)
        }

        //
        var lowerIndexOffset: Int = 0
        var upperIndexOffset: Int = 0
        // Edit text contain mention users
        if !overlapMessageRanges.isEmpty {
            let firstMentionRange = overlapMessageRanges.first!
            let lastMentionRange = overlapMessageRanges.last!
            // Extent current message range if ovverlap mention range bound large than message range
            if !messageTextRange.contains(firstMentionRange.lowerBound) {
                messageTextRange = Range(uncheckedBounds: (firstMentionRange.lowerBound, messageTextRange.upperBound))
            }

            if !messageTextRange.contains(lastMentionRange.upperBound) {
                messageTextRange = Range(uncheckedBounds: (messageTextRange.lowerBound, lastMentionRange.upperBound))
            }

            updatedText = currentText.replacingCharacters(in: messageTextRange, with: replaceText)

            // calculate offset
            let firstMentionRangeIndex = overlapMessageRangeIndexs.first!
            let lastMentionRangeIndex = overlapMessageRangeIndexs.last!
            upperIndexOffset = calculateMentionIndexOffset(at: lastMentionRangeIndex)
            lowerIndexOffset = calculateMentionIndexOffset(at: firstMentionRangeIndex - 1)
        } else {
            let nearestLowerRangeIndex = mentionIndex.messageRanges.lastIndex(where: {
                currentText.distance(from: $0.upperBound, to: messageTextRange.lowerBound) >= 0
            }) ?? -1
            lowerIndexOffset = calculateMentionIndexOffset(at: nearestLowerRangeIndex)
            upperIndexOffset = lowerIndexOffset
        }
        let tempText = content.text.appending(currentText)
        let contentRangeLowerBound = tempText.index(messageTextRange.lowerBound, offsetBy: lowerIndexOffset)
        let contentRangeUpperBound = tempText.index(messageTextRange.upperBound, offsetBy: upperIndexOffset)
        let contentRange = Range(uncheckedBounds: (contentRangeLowerBound, contentRangeUpperBound))
        // Manual update textView.text
        let changedRange = NSRange(messageTextRange, in: currentText)
        let caretLocation = changedRange.location
        // Fix bug auto captlize text
        self.preventHandleTextChanged = true
        if textView.text != updatedText {
            textView.text = updatedText
            let newCaretLocation = caretLocation + replaceText.count
            textView.selectedRange = NSRange(location: newCaretLocation, length: 0)
        }
        self.shouldAutoUpdateTextViewContent = false
        self.content.text = self.content.text.replacingCharacters(in: contentRange, with: replaceText)
        self.shouldAutoUpdateTextViewContent = true
        self.preventHandleTextChanged = false
        self.previousText = textView.text
    }

    // MARK: - UIImagePickerControllerDelegate

    open func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true) { [weak self] in
            let urlAndType: (URL, AttachmentType)
            if let imageURL = info[.imageURL] as? URL {
                urlAndType = (imageURL, .image)
            } else if let videoURL = info[.mediaURL] as? URL {
                urlAndType = (videoURL, .video)
            } else if let editedImage = info[.editedImage] as? UIImage,
                      let editedImageURL = try? editedImage.temporaryLocalFileUrl() {
                urlAndType = (editedImageURL, .image)
            } else if let originalImage = info[.originalImage] as? UIImage,
                      let originalImageURL = try? originalImage.temporaryLocalFileUrl() {
                urlAndType = (originalImageURL, .image)
            } else {
                log.error("Unexpected item selected in image picker")
                return
            }

            var localAttachmentInfo: [LocalAttachmentInfoKey: Any] = [:]
            if let originalImage = info[.originalImage] {
                localAttachmentInfo[.originalImage] = originalImage
            }

            do {
                try self?.addAttachmentToContent(
                    from: urlAndType.0,
                    type: urlAndType.1,
                    info: localAttachmentInfo
                )
            } catch {
                self?.handleAddAttachmentError(
                    attachmentURL: urlAndType.0,
                    attachmentType: urlAndType.1,
                    error: error
                )
            }
        }
    }

    open func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        if #available(iOS 16, *) {
            let assetIdentifiers = results.compactMap(\.assetIdentifier)
            if !assetIdentifiers.isEmpty {
                picker.deselectAssets(withIdentifiers: results.compactMap(\.assetIdentifier))
            }
        }

        picker.dismiss(animated: true) {
            let loadAttachmentDispatchGroup = DispatchGroup()
            var attachmentResults: [(Int, Result<AttachmentPickerResult, Error>)] = []
            for (index, result) in results.enumerated() {
                loadAttachmentDispatchGroup.enter()
                self.handlePickerResult(result) { result in
                    attachmentResults.append((index, result))
                    loadAttachmentDispatchGroup.leave()
                }
            }

            loadAttachmentDispatchGroup.notify(queue: .main) {
                let attachmentPickerResults = attachmentResults
                    .sorted { $0.0 < $1.0 }
                    .map(\.1)
                    .compactMap({
                        if case let .success(value) = $0 {
                            return value
                        }
                        return nil
                    })
                // Has error when pickup attachment
                if attachmentPickerResults.count < attachmentResults.count {
                    self.presentAlert(title: "Error", message: "Failed to load attachment.")
                    return
                }
                attachmentPickerResults.forEach({
                    do {
                        try self.addAttachmentToContent(
                            from: $0.url,
                            type: $0.attachmentType,
                            info: $0.attachmentInfo
                        )
                    } catch {
                        self.handleAddAttachmentError(
                            attachmentURL: $0.url,
                            attachmentType: $0.attachmentType,
                            error: error
                        )
                        return
                    }
                })
            }
        }
    }

    func handlePickerResult(_ result: PHPickerResult, completion: ((Result<AttachmentPickerResult, Error>) -> Void)?) {
        let prov = result.itemProvider

        if prov.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            prov.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard error == nil else {
                    completion?(.failure(error!))
                    return
                }
                guard let url else {
                    completion?(.failure(ClientError.AttachmentURLNotFound()))
                    return
                }
                do {
                    let tempURL = try url.copyToTemporaryLocalFileUrl()
                    completion?(.success(.init(url: tempURL, attachmentType: .video, attachmentInfo: [:])))
                } catch {
                    completion?(.failure(ClientError.AttachmentURLNotFound()))
                }
            }
        } else if prov.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            prov.loadObject(ofClass: UIImage.self, completionHandler: { [weak prov] item, error in
                guard error == nil else {
                    completion?(.failure(error!))
                    return
                }

                guard let image = item as? UIImage, let url = try? image.temporaryLocalFileUrl(fileName: prov?.suggestedName) else {
                    completion?(.failure(ClientError.AttachmentURLNotFound()))
                    return
                }
                var localAttachmentInfo: [LocalAttachmentInfoKey: Any] = [:]
                localAttachmentInfo[.originalImage] = image

                completion?(.success(.init(url: url, attachmentType: .image, attachmentInfo: localAttachmentInfo)))
            })
        }
    }
    // MARK: - UIDocumentPickerViewControllerDelegate

    open func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for fileURL in urls {
            var attachmentType = AttachmentType(fileExtension: fileURL.pathExtension)
            if attachmentType == .audio {
                attachmentType = .file
            }
            do {
                try addAttachmentToContent(from: fileURL, type: attachmentType, info: [:])
            } catch {
                handleAddAttachmentError(
                    attachmentURL: fileURL,
                    attachmentType: attachmentType,
                    error: error
                )
                break
            }
        }
    }

    /// Shows an alert saying that attachment's size exceeds the limit.
    open func showAttachmentExceedsMaxSizeAlert() {
        presentAlert(message: L10n.Attachment.maxSizeExceeded)
    }

    // MARK: - InputTextViewClipboardAttachmentDelegate

    open func inputTextView(_ inputTextView: InputTextView, didPasteImage image: UIImage) {
        guard let imageUrl = try? image.temporaryLocalFileUrl() else {
            log.error("Could not create temporary local file from image")
            return
        }

        let type: AttachmentType = .image
        do {
            try addAttachmentToContent(
                from: imageUrl,
                type: type,
                info: [.originalImage: image]
            )
        } catch {
            handleAddAttachmentError(
                attachmentURL: imageUrl,
                attachmentType: type,
                error: error
            )
        }
    }

    // MARK: - VoiceRecordingDelegate

    public func voiceRecording(
        _ voiceRecordingVC: VoiceRecordingViewController,
        addAttachmentFromLocation location: URL,
        duration: TimeInterval,
        waveformData: [Float]
    ) {
        do {
            try addAttachmentToContent(
                from: location,
                type: .voiceRecording,
                info: [
                    .duration: duration,
                    .waveformData: waveformData
                ]
            )
        } catch {
            handleAddAttachmentError(
                attachmentURL: location,
                attachmentType: .voiceRecording,
                error: error
            )
        }
    }

    public func voiceRecordingPublishMessage(_ voiceRecordingVC: VoiceRecordingViewController) {
        publishMessage(sender: composerView.sendButton)
    }

    public func voiceRecordingWillBeginRecording(_ voiceRecordingVC: VoiceRecordingViewController) {
        /* No-op */
    }

    public func voiceRecordingDidBeginRecording(_ voiceRecordingVC: VoiceRecordingViewController) {
        content.recording()
    }

    public func voiceRecordingDidLockRecording(_ voiceRecordingVC: VoiceRecordingViewController) {
        content.recordingLocked()
    }

    public func voiceRecordingDidStopRecording(_ voiceRecordingVC: VoiceRecordingViewController) {
        content = .init(
            text: content.text,
            state: .new,
            editingMessage: content.editingMessage,
            quotingMessage: content.quotingMessage,
            threadMessage: content.threadMessage,
            attachments: content.attachments,
            mentionedUsers: content.mentionedUsers,
            mentionedAll: content.hasMentionedAll,
            command: content.command
        )
    }

    public func voiceRecording(
        _ voiceRecordingVC: VoiceRecordingViewController,
        presentFloatingView floatingView: UIView
    ) {
        if let parent = parent {
            floatingView.translatesAutoresizingMaskIntoConstraints = false
            parent.view.addSubview(floatingView)
            NSLayoutConstraint.activate([
                floatingView.leadingAnchor.pin(equalTo: parent.view.leadingAnchor),
                floatingView.trailingAnchor.pin(equalTo: parent.view.trailingAnchor),
                composerView.topAnchor.pin(equalTo: floatingView.bottomAnchor),
                floatingView.topAnchor.pin(greaterThanOrEqualTo: parent.view.safeAreaLayoutGuide.topAnchor)
            ])
        }
    }

    // MARK: - ComposerBlockedViewDelegate
    public func composerBlockedViewDidSelectUnblockUser(in view: ComposerBlockedView) {
        view.unBlockedButton.isEnabled = false
        channelController?.toggleBlockedChannelState(completion: { [weak self] result in
            switch result {
            case .success:
                DispatchQueue.main.async {
                    self?.updateComposerDisableView()
                }
            case .failure:
                DispatchQueue.main.async {
                    self?.presentAlert(title: "Unable to unblock the user. Please try again.")
                }
            }
            view.unBlockedButton.isEnabled = true
        })
    }
    // MARK: - ComposerGuestViewDelegate
    public func composerGuestViewDidSelectJoinChannel(in view: ComposerGuestView) {
        view.joinChannelButton.isEnabled = false
        channelController?.joinPublicChannel(completion: { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.presentAlert(title: "Unable to join this channel. Please try again.")
                }
            } else {
                self?.updateComposerDisableView()
            }
            view.joinChannelButton.isEnabled = true
        })
    }
    // MARK: - Private

    private func presentAlert(
        title: String? = nil,
        message: String? = nil,
        preferredStyle: UIAlertController.Style = .alert,
        actions: [UIAlertAction] = [
            .init(title: L10n.Alert.Actions.ok, style: .default, handler: { _ in })
        ],
        sourceView: UIView? = nil
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: preferredStyle)
        alert.popoverPresentationController?.sourceView = sourceView
        actions.forEach(alert.addAction)

        present(alert, animated: true)
    }

    func insertMentionObject(_ mentionObject: MentionSuggestionView.Content, at mentionRange: NSRange, typingMention: String) {
        let textView = self.composerView.inputMessageView.textView
        let text = textView.text as NSString
        let mentionString = mentionObject.mentionString + " "
        let mentionDisplayString = mentionObject.mentionsDisplayString + " "

        guard mentionRange.length <= mentionDisplayString.count else {
            return self.dismissSuggestions()
        }

        let currentText = textView.text ?? ""

        let newRange = NSRange(location: mentionRange.location - 1,
                               length: mentionRange.length + 1)
        guard var messageTextRange = Range(newRange, in: currentText) else {
            return
        }

        mentionIndex = calculateMentionIndex(message: currentText)

        guard let mentionIndex = mentionIndex else {
            return
        }

        var containOtherMention: Bool = false

        shouldAutoUpdateTextViewContent = false

        var overlapMessageRanges: [Range<String.Index>] = []
        var overlapMessageRangeIndexs: [Int] = []

        for (index, messageRange) in mentionIndex.messageRanges.enumerated() {
            let nsRange = NSRange(messageRange, in: currentText)
            guard let range = Range(nsRange, in: currentText) else {
                continue
            }
            if range.overlaps(messageTextRange) {
                overlapMessageRanges.append(range)
                overlapMessageRangeIndexs.append(index)
            }
        }

        var replaceText = mentionDisplayString
        var updatedText = text.replacingCharacters(in: newRange, with: mentionDisplayString)
        var lowerIndexOffset: Int = 0
        var upperIndexOffset: Int = 0
        // Removed mention user if needed
        if !overlapMessageRanges.isEmpty {
            var removedUsers: Set<ChatUser> = []
            let overlapContentRanges = overlapMessageRangeIndexs.map { mentionIndex.contentRanges[$0] }
            for mentionedUser in content.mentionedUsers {
                let mentionString = mentionedUser.mentionString
                let ranges = content.text.ranges(of: mentionString)
                if ranges.allSatisfy({ range in
                    return overlapContentRanges.contains { overlapContentRange in
                        overlapContentRange.contains(range.lowerBound) && overlapContentRange.contains(range.upperBound)
                    }
                }) {

                    removedUsers.insert(mentionedUser)
                }
            }
            content.mentionedUsers = content.mentionedUsers.subtracting(removedUsers)
        }
        if !overlapMessageRanges.isEmpty {
            let firstMentionRange = overlapMessageRanges.first!
            let lastMentionRange = overlapMessageRanges.last!
            // Extent current message range if ovverlap mention range bound large than message range
            if !messageTextRange.contains(firstMentionRange.lowerBound) {
                messageTextRange = Range(uncheckedBounds: (firstMentionRange.lowerBound, messageTextRange.upperBound))
            }

            if !messageTextRange.contains(lastMentionRange.upperBound) {
                messageTextRange = Range(uncheckedBounds: (messageTextRange.lowerBound, lastMentionRange.upperBound))
            }
            updatedText = currentText.replacingCharacters(in: messageTextRange, with: mentionDisplayString)
            // Calculate offset
            let firstMentionRangeIndex = overlapMessageRangeIndexs.first!
            let lastMentionRangeIndex = overlapMessageRangeIndexs.last!
            upperIndexOffset = calculateMentionIndexOffset(at: lastMentionRangeIndex)
            lowerIndexOffset = calculateMentionIndexOffset(at: firstMentionRangeIndex - 1)
        } else {
            let nearestLowerRangeIndex = mentionIndex.messageRanges.lastIndex(where: {
                currentText.distance(from: $0.upperBound, to: messageTextRange.lowerBound) >= 0
            }) ?? -1
            lowerIndexOffset = calculateMentionIndexOffset(at: nearestLowerRangeIndex)
            upperIndexOffset = lowerIndexOffset
        }

        let tempText = content.text.appending(currentText)
        let contentRangeLowerBound = tempText.index(messageTextRange.lowerBound, offsetBy: lowerIndexOffset)
        let contentRangeUpperBound = tempText.index(messageTextRange.upperBound, offsetBy: upperIndexOffset)


        let caretLocation = textView.selectedRange.location
        let newCaretLocation = caretLocation + (mentionDisplayString.count - typingMention.count)
        textView.selectedRange = NSRange(location: newCaretLocation, length: 0)

        guard let messageRange = textView.text.range(from: mentionRange) else {
            return self.dismissSuggestions()
        }

        let contentRange = Range(uncheckedBounds: (lower: contentRangeLowerBound, upper: contentRangeUpperBound))

        switch mentionObject {
        case .allUser:
            self.content.hasMentionedAll = true
        case .mention(let chatUser):
            self.content.mentionedUsers.insert(chatUser)
        }
        self.preventHandleTextChanged = true
        self.shouldAutoUpdateTextViewContent = false

        self.content.text = content.text.replacingCharacters(in: contentRange, with: mentionString)
        textView.text = updatedText

        self.preventHandleTextChanged = false
        self.shouldAutoUpdateTextViewContent = true
        self.updateMentionSuggestions()
    }

    /// searchUsers does an autocomplete search on a list of ChatUser and returns users with `id` or `name` containing the search string
    /// results are returned sorted by their edit distance from the searched string
    /// distance is calculated using the levenshtein algorithm
    /// both search and name strings are normalized (lowercased and by replacing diacritics)
    func searchUsers(_ users: [ChatUser], by searchInput: String, excludingId: String? = nil) -> [ChatUser] {
        let normalize: (String) -> String = {
            $0.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        }
    
        let searchInput = normalize(searchInput)
    
        let matchingUsers = users.filter { $0.id != excludingId }
            .filter { searchInput.isEmpty || $0.id.contains(searchInput) || (normalize($0.name ?? "").contains(searchInput)) }
    
        let distance: (ChatUser) -> Int = {
            min($0.id.levenshtein(searchInput), $0.name?.levenshtein(searchInput) ?? 1000)
        }
    
        return Array(Set(matchingUsers)).sorted {
            /// a tie breaker is needed here to avoid results from flickering
            let dist = distance($0) - distance($1)
            if dist == 0 {
                return $0.id < $1.id
            }
            return dist < 0
        }
    }
}
// MARK: - ChannelControllerDelegate
extension ComposerViewController: ChannelControllerDelegate {
    public func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    ) {
        cooldownTracker.start(with: channelController.currentCooldownTime())
    }

    public func channelController(_ channelController: ChannelController, didUpdateChannel channel: EntityChange<Channel>) {
        updateComposerDisableView()
        updateContentIfNeeded()
    }

    public func channelController(_ channelController: ChannelController, didReceiveMemberEvent: any MemberEvent) {
        updateComposerDisableView()
        updateContentIfNeeded()
    }
}
// MARK: - Helper for mention users
extension ComposerViewController {
    func calculateMentionIndex(message: String) -> MentionsIndex {
        let mentionsUserIds = content.mentionedUsers.map(\.userId)

        // Range of mention user id in text content.
        var contentRanges: [Range<String.Index>] = []
        contentRanges = content.mentionedUsers.reduce(into: contentRanges) { partialResult, mentionUser in
            return partialResult.append(contentsOf: content.text.ranges(of: mentionUser.mentionString))
        }

        var messageRanges: [Range<String.Index>] = []

        var indexOffsets: [Int] = []
        var indexOffset = 0
        for contentRange in contentRanges.sorted(by: { $0.lowerBound < $1.lowerBound}) {
            let mentionString = String(content.text[contentRange])
            guard let mentionUser = content.mentionedUsers.first(where: { mentionString.contains($0.userId)}) else {
                continue
            }
            let mentionsDisplayString = mentionUser.mentionsDisplayString
            let testRange = message.ranges(of: mentionsDisplayString)
            let mentionDisplayLength = mentionsDisplayString.distance(from: mentionsDisplayString.startIndex, to: mentionsDisplayString.endIndex)
            let location = NSRange(contentRange, in: content.text).location
            let messageRange = NSRange(location: location + indexOffset, length: mentionDisplayLength)

            indexOffset += mentionDisplayLength - mentionString.count
            messageRanges.append(
                 message.range(from: messageRange)!
            )
            indexOffsets.append(indexOffset)
        }

        return MentionsIndex(contentRanges: contentRanges,
                             messageRanges: messageRanges,
                             indexOffsets: indexOffsets)
    }
    // Must call calculate mention info before
    func calculateMentionIndexOffset(at mentionIndex: Int? = nil) -> Int {
        var indexOffset: Int = 0
        guard let indexOffsets = self.mentionIndex?.indexOffsets else { return indexOffset }
        for (index, offset) in indexOffsets.enumerated() {
            if let mentionIndex = mentionIndex, index > mentionIndex {
                break
            }
            indexOffset = -offset
        }
        return indexOffset
    }

    struct MentionsIndex {
        var contentRanges: [Range<String.Index>]
        var messageRanges: [Range<String.Index>]
        var indexOffsets: [Int]
    }

    func removeOverlapMentionUserIfNeeded(changeTextRange: NSRange, currentText: String) {
        guard var messageTextRange = Range(changeTextRange, in: currentText) else {
            return
        }

        mentionIndex = calculateMentionIndex(message: currentText)

        guard let mentionIndex = mentionIndex else {
            return
        }

        shouldAutoUpdateTextViewContent = false

        var overlapMessageRanges: [Range<String.Index>] = []
        var overlapMessageRangeIndexs: [Int] = []

        for (index, messageRange) in mentionIndex.messageRanges.enumerated() {
            let nsRange = NSRange(messageRange, in: currentText)
            guard let range = Range(nsRange, in: currentText) else {
                continue
            }
            if range.overlaps(messageTextRange) {
                overlapMessageRanges.append(range)
                overlapMessageRangeIndexs.append(index)
            }
        }

        // Removed mention user if needed
        if !overlapMessageRanges.isEmpty {
            var removedUsers: Set<ChatUser> = []
            let overlapContentRanges = overlapMessageRangeIndexs.map { mentionIndex.contentRanges[$0] }
            for mentionedUser in content.mentionedUsers {
                let mentionString = mentionedUser.mentionString
                let ranges = content.text.ranges(of: mentionString)
                if ranges.allSatisfy({ range in
                    return overlapContentRanges.contains { overlapContentRange in
                        overlapContentRange.contains(range.lowerBound) && overlapContentRange.contains(range.upperBound)
                    }
                }) {
                    removedUsers.insert(mentionedUser)
                }
            }
            content.mentionedUsers = content.mentionedUsers.subtracting(removedUsers)
        }
    }
}

extension ComposerViewController {
    struct AttachmentPickerResult {
        let url: URL
        let attachmentType: AttachmentType
        let attachmentInfo: [LocalAttachmentInfoKey: Any]
    }
}
