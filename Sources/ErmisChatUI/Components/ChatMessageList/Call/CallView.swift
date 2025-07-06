//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

open class CallView: _View, ThemeProvider {

    public private(set) lazy var imageView = createImageView()
    public private(set) lazy var titleStackView = createTitleStackView()
    public private(set) lazy var titleLabel = createTitleLabel()
    public private(set) lazy var descriptionLabel = createDescriptionLabel()
    public private(set) lazy var durationFormater = createDurationFormatter()

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        addSubviews([
            imageView,
            titleStackView,
        ])

        imageView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 8).isActive = true
        imageView.pin(anchors: [.leading], to: self, contant: 8)
        imageView.pin(anchors: [.centerY], to: self)
        imageView.pin(anchors: [.width, .height], to: 40)

        titleStackView.pin(anchors: [.centerY], to: imageView)
        titleStackView.leadingAnchor.pin(equalTo: imageView.trailingAnchor, constant: 8).isActive = true
        titleStackView.pin(anchors: [.trailing], to: self, contant: -16)
        titleStackView.pin(anchors: [.top], to: self, contant: 8)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        switch content?.endedReason {
        case .cancelled, .noAnswer, .rejected, .busy:
            imageView.tintColor = theme.colors.error
        case .normal:
            imageView.tintColor = theme.colors.success
        case nil:
            imageView.tintColor = theme.colors.success
        }

        titleLabel.textColor = theme.colors.incommingMessageText
        titleLabel.font = theme.fonts.body.bold
        descriptionLabel.textColor = theme.colors.subtitleText
        descriptionLabel.font = theme.fonts.body
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        guard let content else {
            return
        }

        updateImageView()
        titleLabel.text = content.title
        if let duration = content.duration {
            descriptionLabel.text = durationFormater.string(from: duration)
            descriptionLabel.isHidden = false
        } else {
            descriptionLabel.text = nil
            descriptionLabel.isHidden = true
        }
        setUpTheme()
    }

    private func updateImageView() {
        guard let content, let endedReason = content.endedReason else {
            return
        }
        switch endedReason {
        case .cancelled:
            imageView.image = content.isVideoCall ? theme.icons.videoCallMissing : theme.icons.audioCallMissing
        case .noAnswer:
            imageView.image = content.isVideoCall ? theme.icons.videoCallMissing : theme.icons.audioCallMissing
        case .rejected:
            imageView.image = content.isVideoCall ? theme.icons.videoCallMissing : theme.icons.audioCallMissing
        case .busy:
            imageView.image = content.isVideoCall ? theme.icons.videoCallMissing : theme.icons.audioCallMissing
        case .normal:
            if content.isSentByCurrentUser {
                imageView.image = content.isVideoCall ? theme.icons.videoCallOutgoing : theme.icons.audioCallOutgoing
            } else {
                imageView.image = content.isVideoCall ? theme.icons.videoCallIncoming : theme.icons.audioCallIncoming
            }
        }
    }
}

extension CallView {
    private func createImageView() -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .center
        imageView.clipsToBounds = true
        return imageView.withoutAutoresizingMaskConstraints
    }

    private func createTitleStackView() -> ContainerStackView {
        let stackView = ContainerStackView()
        stackView.alignment = .leading
        stackView.axis = .vertical
        stackView.spacing = 2
        stackView.addArrangedSubviews([titleLabel, descriptionLabel])
        return stackView.withoutAutoresizingMaskConstraints
    }

    private func createTitleLabel() -> UILabel {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
    }

    private func createDescriptionLabel() -> UILabel {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
    }

    private func createDurationFormatter() -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }
}

public
extension CallView {
    struct Content {
        var signalMessage: SignalMessage?
        var isVideoCall: Bool
        var isSentByCurrentUser: Bool
        var endedReason: CallEndedReason?

        public init(signalMessage: SignalMessage?,
                    isVideoCall: Bool,
                    isSentByCurrentUser: Bool,
                    endedReason: CallEndedReason?) {
            self.signalMessage = signalMessage
            self.isVideoCall = isVideoCall
            self.isSentByCurrentUser = isSentByCurrentUser
            self.endedReason = endedReason
        }

        public init(chatMessage: ChatMessage?) {
            guard let chatMessage else {
                self = .init(signalMessage: nil, isVideoCall: false, isSentByCurrentUser: false, endedReason: nil)
                return
            }
            self.signalMessage = chatMessage.signalMessage
            self.isSentByCurrentUser = chatMessage.isSentByCurrentUser ?? false
            self.isVideoCall = signalMessage?.isVideo ?? false
            self.endedReason = signalMessage?.endedReason
        }

        public var title: String? {
            switch endedReason {
            case .cancelled:
                return isSentByCurrentUser ? canceledCallText : missedCallText
            case .noAnswer:
                return isSentByCurrentUser ? outgoingCallText : missedCallText
            case .rejected:
                return isSentByCurrentUser ? rejectedCallByReceiverText : rejectedCallByMeText
            case .busy:
                return isSentByCurrentUser ? busyCallText : missedCallText
            case .normal:
                return isSentByCurrentUser ? outgoingCallText : incomingCallText
            case nil:
                return nil
            }
        }

        public var duration: TimeInterval? {
            switch signalMessage {
            case .audioCallEnded(let userId, let enderId, let duration):
                guard duration != 0 else {
                    return nil
                }
                return TimeInterval(duration / 1000)
            case .videoCallEnded(let userId, let enderId, let duration):
                guard duration != 0 else {
                    return nil
                }
                return TimeInterval(duration / 1000)
            case .audioCallMissed, .videoCallMissed:
                if endedReason == .noAnswer, isSentByCurrentUser {
                    return 0
                }
                return nil
            default:
                return nil
            }
        }

        private var missedCallText: String {
            return isVideoCall ? L10n.Message.Call.missedVideoCall : L10n.Message.Call.missedAudioCall
        }

        private var canceledCallText: String {
            return isVideoCall ? L10n.Message.Call.videoCanceledByMe : L10n.Message.Call.audioCanceledByMe
        }

        private var rejectedCallByMeText: String {
            return isVideoCall ? L10n.Message.Call.videoRejectedByMe : L10n.Message.Call.audioRejectedByMe
        }

        private var rejectedCallByReceiverText: String {
            return isVideoCall ? L10n.Message.Call.videoRejectedByReceiver : L10n.Message.Call.audioRejectedByReceiver
        }

        private var busyCallText: String {
            return L10n.Message.Call.receiverBusy
        }

        private var outgoingCallText: String {
            return isVideoCall ? L10n.Message.Call.outgoingVideoCall : L10n.Message.Call.outgoingAudioCall
        }

        private var incomingCallText: String {
            return isVideoCall ? L10n.Message.Call.incomingVideoCall : L10n.Message.Call.incomingAudioCall
        }
    }
}
