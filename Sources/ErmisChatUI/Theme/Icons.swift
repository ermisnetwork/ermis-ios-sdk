//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public extension Theme {
    struct Icons {
        /// A private internal function that will safely load an image from the bundle or return a circle image as backup
        /// - Parameter imageName: The required image name to load from the bundle
        /// - Returns: A UIImage that is either the correct image from the bundle or backup circular image
        private static func loadImageSafely(with imageName: String) -> UIImage {
            if let image = UIImage(named: imageName, in: .ermisChatUI) {
                return image
            } else {
                log.error(
                    """
                    \(imageName) image has failed to load from the bundle please make sure it's included in your assets folder.
                    A default image has been added.
                    """
                )
                return UIImage(systemName: "app")!
            }
        }

        private static func loadSafely(systemName: String, assetsFallback: String = "app") -> UIImage {
            return UIImage(systemName: systemName) ?? loadImageSafely(with: assetsFallback)

        }

        // MARK: - General

        public var loadingIndicator: UIImage = loadImageSafely(with: "loading_indicator")
        public var close: UIImage = loadSafely(systemName: "xmark", assetsFallback: "close")
        public var discard: UIImage = loadImageSafely(with: "close")
        public var link: UIImage = loadImageSafely(with: "link")

        public var closeCircleTransparent: UIImage = loadImageSafely(with: "close_circle_transparent")
        public var discardAttachment: UIImage = loadImageSafely(with: "close_circle_filled")
        public var back: UIImage = loadImageSafely(with: "icn_back")
        public var onlyVisibleToCurrentUser = loadImageSafely(with: "eye")
        public var more = loadImageSafely(with: "icn_more")
        public var share: UIImage = loadSafely(systemName: "square.and.arrow.up", assetsFallback: "share")

        public var add: UIImage = loadSafely(systemName: "plus")
        public var commands: UIImage = loadImageSafely(with: "bolt")
        public var smallBolt: UIImage = loadImageSafely(with: "bolt_small")
        public var openAttachments: UIImage = loadImageSafely(with: "clip")
        public var send: UIImage = loadImageSafely(with: "arrow_send")
        public var scrollDownArrow: UIImage = loadImageSafely(with: "arrow_down")
        public var whiteCheckmark: UIImage = loadImageSafely(with: "checkmark_white")
        public var confirmCheckmark: UIImage = loadImageSafely(with: "checkmark_confirm")
        public var bigConfirmCheckmark: UIImage = loadImageSafely(with: "checkmark_confirm_big")
        public var folder: UIImage = loadImageSafely(with: "folder")
        public var restart: UIImage = loadImageSafely(with: "restart")
        public var emptyContactList: UIImage = loadImageSafely(with: "empty_contact_list")
        public var emptySearch: UIImage = loadImageSafely(with: "empty_search")
        public var download: UIImage = loadSafely(systemName: "download", assetsFallback: "download")
        public var sticker: UIImage = loadSafely(systemName: "face.smiling")
        public var recents: UIImage = loadImageSafely(with: "recents")
        public var photo: UIImage = loadImageSafely(with: "photo")
        public var check: UIImage = loadImageSafely(with: "ic_check")
        public var info: UIImage = loadImageSafely(with: "ic_info")
        public var block: UIImage = loadImageSafely(with: "block")
        public var mute: UIImage = loadImageSafely(with: "ic_mute_user")
        public var favorite: UIImage = loadImageSafely(with: "ic_favorite")
        // Composer Menu
        public var composerMenuLocation: UIImage = loadSafely(systemName: "location.circle.fill")
        public var composerMenuFile: UIImage = loadSafely(systemName: "document.circle")
        public var composerMenuPoll: UIImage = loadSafely(systemName: "chart.bar.xaxis.ascending")
        public var topicOpen: UIImage = loadImageSafely(with: "ic_topic_open")
        // MARK: - Recording

        public var mic: UIImage = loadSafely(systemName: "mic", assetsFallback: "mic")
        public var lock: UIImage = loadSafely(systemName: "lock", assetsFallback: "lock")
        public var chevronLeft: UIImage = loadSafely(systemName: "chevron.left", assetsFallback: "chevron.left")
        public var chevronRight: UIImage = loadSafely(systemName: "chevron.right", assetsFallback: "cheveron.right")
        public var chevronUp: UIImage = loadSafely(systemName: "chevron.up", assetsFallback: "chevron.up")
        public var trash: UIImage = loadSafely(systemName: "trash", assetsFallback: "trash")
        public var stop: UIImage = loadSafely(systemName: "stop.circle", assetsFallback: "")
        public var playFill: UIImage = loadSafely(systemName: "play.fill", assetsFallback: "play.fill")
        public var pauseFill: UIImage = loadSafely(systemName: "pause.fill", assetsFallback: "pause.fill")
        public var recordingPlay: UIImage = loadSafely(systemName: "play", assetsFallback: "play_big")
        public var recordingPause: UIImage = loadSafely(systemName: "pause", assetsFallback: "pause.fill")
        public var rateButtonPillBackground: UIImage = loadImageSafely(with: "pill")
        public var sliderThumb: UIImage = loadImageSafely(with: "sliderThumb")

        // MARK: - Message Receipts

        public var messageDeliveryStatusSending: UIImage = loadImageSafely(with: "message_receipt_sending")
        public var messageDeliveryStatusSent: UIImage = loadImageSafely(with: "message_receipt_sent")
        public var messageDeliveryStatusRead: UIImage = loadImageSafely(with: "message_receipt_read")
        public var messageDeliveryStatusFailed: UIImage = loadImageSafely(with: "message_receipt_failed")

        // MARK: - Reactions

        private var _availableReactions: [MessageReactionType: MessageReactionAppearanceType]?
        public var availableReactions: [MessageReactionType: MessageReactionAppearanceType] {
            get {
                _availableReactions ??
                    [
                        "haha": MessageReactionAppearance(emojiString:"😂", positionValue: 0),
                        "like": MessageReactionAppearance(emojiString:"👍", positionValue: 1),
                        "love": MessageReactionAppearance(emojiString:"❤️", positionValue: 2),
                        "sad": MessageReactionAppearance(emojiString:"😔", positionValue: 3),
                        "fire": MessageReactionAppearance(emojiString:"🔥", positionValue: 4)
                    ]
            }
            set {
                _availableReactions = newValue
            }
        }

        // MARK: - MessageList

        public var messageListErrorIndicator: UIImage = loadImageSafely(with: "error_indicator")

        // MARK: - FileIcons

        public var file7z: UIImage = loadImageSafely(with: "7z")
        public var fileAac: UIImage = loadImageSafely(with: "aac")
        public var fileCsv: UIImage = loadImageSafely(with: "csv")
        public var fileDoc: UIImage = loadImageSafely(with: "doc")
        public var fileDocx: UIImage = loadImageSafely(with: "docx")
        public var fileHtml: UIImage = loadImageSafely(with: "html")
        public var fileMd: UIImage = loadImageSafely(with: "md")
        public var fileMp3: UIImage = loadImageSafely(with: "mp3")
        public var fileOdt: UIImage = loadImageSafely(with: "odt")
        public var filePdf: UIImage = loadImageSafely(with: "pdf")
        public var filePpt: UIImage = loadImageSafely(with: "ppt")
        public var filePptx: UIImage = loadImageSafely(with: "pptx")
        public var fileRar: UIImage = loadImageSafely(with: "rar")
        public var fileRtf: UIImage = loadImageSafely(with: "rtf")
        public var fileTargz: UIImage = loadImageSafely(with: "tar.gz")
        public var fileTxt: UIImage = loadImageSafely(with: "txt")
        public var fileXls: UIImage = loadImageSafely(with: "xls")
        public var fileXlsx: UIImage = loadImageSafely(with: "xlsx")
        public var filezip: UIImage = loadImageSafely(with: "zip")
        public var fileFallback: UIImage = loadImageSafely(with: "generic")

        private var _documentPreviews: [String: UIImage]?

        public var documentPreviews: [String: UIImage] {
            get { _documentPreviews ??
                [
                    "7z": file7z,
                    "aac": fileAac,
                    "csv": fileCsv,
                    "doc": fileDoc,
                    "docx": fileDocx,
                    "html": fileHtml,
                    "md": fileMd,
                    "mp3": fileMp3,
                    "odt": fileOdt,
                    "pdf": filePdf,
                    "ppt": filePpt,
                    "pptx": filePptx,
                    "rar": fileRar,
                    "rtf": fileRtf,
                    "tar.gz": fileTargz,
                    "txt": fileTxt,
                    "xls": fileXls,
                    "xlsx": fileXlsx,
                    "zip": filezip
                ]
            }
            set { _documentPreviews = newValue }
        }

        private var _fileIcons: [AttachmentFileType: UIImage]?
        public var fileIcons: [AttachmentFileType: UIImage] {
            get { _fileIcons ??
                [AttachmentFileType: UIImage](
                    uniqueKeysWithValues: AttachmentFileType.allCases.compactMap {
                        guard let icon = UIImage(named: $0.rawValue, in: .ermisChatUI) else { return nil }
                        return ($0, icon)
                    }
                )
            }
            set { _fileIcons = newValue }
        }

        // MARK: - Message Actions

        public var messageActionSwipeReply: UIImage = loadImageSafely(with: "ic_inline_reply")
        public var messageActionInlineReply: UIImage = loadImageSafely(with: "ic_inline_reply")
        public var messageActionThreadReply: UIImage = loadImageSafely(with: "ic_thread_reply")
        public var messageActionMarkUnread: UIImage = loadSafely(systemName: "message.badge", assetsFallback: "mark_unread")

        public var messageActionEdit: UIImage = loadImageSafely(with: "ic_edit")
        public var messageActionDownload: UIImage = loadImageSafely(with: "download")
        public var messageActionCopy: UIImage = loadImageSafely(with: "ic_copy")
        public var messageActionForward: UIImage = loadImageSafely(with: "ic_forward")
        public var messageActionPin: UIImage = loadImageSafely(with: "ic_pin")
        public var messageActionUnpin: UIImage = loadImageSafely(with: "ic_unpin")
        public var messageActionShowInChat: UIImage = loadImageSafely(with: "ic_show_in_chat")
        public var messageActionBlockUser: UIImage = loadImageSafely(with: "ic_block_user")
        public var messageActionMuteUser: UIImage = loadImageSafely(with: "ic_mute_user")
        public var messageActionDelete: UIImage = loadImageSafely(with: "ic_delete")
        public var messageActionResend: UIImage = loadImageSafely(with: "ic_resend")
        public var messageActionFlag: UIImage = loadImageSafely(with: "ic_flag")
        
        // MARK: - FileAttachmentIcons

        private var _fileAttachmentActionIcons: [LocalAttachmentState?: UIImage]?
        public var fileAttachmentActionIcons: [LocalAttachmentState?: UIImage] {
            get { _fileAttachmentActionIcons ??
                [
                    // Uncomment when download feature is done
                    // .uploaded: download,
                    .uploadingFailed: restart,
                    nil: folder
                ]
            }
            set { _fileAttachmentActionIcons = newValue }
        }

        public var camera: UIImage = loadImageSafely(with: "camera")
        public var bigPlay: UIImage = loadImageSafely(with: "play_big")

        public var play: UIImage = loadImageSafely(with: "play")
        public var pause: UIImage = loadImageSafely(with: "pause")

        // MARK: - CommandIcons

        public var commandBan: UIImage = loadImageSafely(with: "command_ban")
        public var commandFlag: UIImage = loadImageSafely(with: "command_flag")
        public var commandImgur: UIImage = loadImageSafely(with: "command_imgur")
        public var commandMention: UIImage = loadImageSafely(with: "command_mention")
        public var commandMute: UIImage = loadImageSafely(with: "command_mute")
        public var commandUnban: UIImage = loadImageSafely(with: "command_unban")
        public var commandUnmute: UIImage = loadImageSafely(with: "command_unmute")
        public var commandFallback: UIImage = loadImageSafely(with: "command_fallback")

        private var _commandIcons: [String: UIImage]?
        public var commandIcons: [String: UIImage] {
            get { _commandIcons ??
                [
                    "ban": commandBan,
                    "flag": commandFlag,
                    "imgur": commandImgur,
                    "mention": commandMention,
                    "mute": commandMute,
                    "unban": commandUnban,
                    "unmute": commandUnmute
                ]
            }
            set { _commandIcons = newValue }
        }

        // MARK: - Call
        public var audioCallIncoming: UIImage = loadImageSafely(with: "audio_call_incoming")
        public var audioCallOutgoing: UIImage = loadImageSafely(with: "audio_call_outgoing")
        public var audioCallMissing: UIImage = loadImageSafely(with: "audio_call_missing")
        public var videoCallIncoming: UIImage = loadImageSafely(with: "video_call_incoming")
        public var videoCallOutgoing: UIImage = loadImageSafely(with: "video_call_outgoing")
        public var videoCallMissing: UIImage = loadImageSafely(with: "video_call_missing")
        public var ongoingCall: UIImage = loadImageSafely(with: "ongoing_call")
    }
}
