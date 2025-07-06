//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChatUI
import AVFAudio

public protocol CallControlViewDelegate: AnyObject {
    func callControlView(_ view: CallControlView, didSelect buttonType: CallControlButtonType)
}
/// A view show control buttons in call screen.
open class CallControlView: _View, UIProvider, CallComponentsProvider {
    /// All type of button will show in controls view.
    open var buttonTypes: [CallControlButtonType] = [
        .speaker,
        .mic,
        .video,
        .switchCamera,
        .endCall
    ]

    public weak var delegate: CallControlViewDelegate?

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    @MainActor required public init(buttonTypes: [CallControlButtonType] = [.speaker,
                                                                            .mic,
                                                                            .video,
                                                                            .switchCamera, .endCall]) {
        self.buttonTypes = buttonTypes
        super.init(frame: .zero)
    }
    
    @MainActor required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open override func setUp() {
        super.setUp()

    }

    open override func setUpUI() {
        super.setUpUI()
        let buttons = buttonTypes.map { callComponents.controlButton.init(type: $0).withoutAutoresizingMaskConstraints }
        buttons.forEach { button in
            button.widthAnchor.pin(equalTo: button.heightAnchor).isActive = true
            button.didTap = { [weak self] in
                guard let self else { return }
                self.delegate?.callControlView(self, didSelect: button.type)
            }
        }
        let stackView = ContainerStackView(axis: .horizontal, distribution: .equal).withoutAutoresizingMaskConstraints
        self.addSubview(stackView)
        stackView.pin(to: self)
        stackView.addArrangedSubviews(buttons)
    }

    open override func setUpTheme() {
        super.setUpTheme()
    }

    open override func contentDidChanged() {
        guard let content else {
            return
        }
        if let speakerButton = getButton(of: .speaker) {
            speakerButton.setImage(content.currentPort == .builtInReceiver ? Theme.Icons.speakerOff: Theme.Icons.speakerOn, for: .normal)
        }
        if let audioButton = getButton(of: .mic) {
            audioButton.setImage(content.isAudioEnable ? Theme.Icons.audioMuteOn : Theme.Icons.audioMuteOff, for: .normal)
        }
        if let videoButton = getButton(of: .video) {
            videoButton.setImage(content.isVideoEnable ? Theme.Icons.videoMuteOn : Theme.Icons.videoMuteOff, for: .normal)
        }
    }

    /// Return control button of given `CallControlButtonType`
    ///
    /// - Parameters:
    ///  - type: The `CallControlButtonType` of control button you want to get.
    /// - Returns: Return control button of given type.
    public func getButton(of type: CallControlButtonType) -> CallControlButton? {
        guard let stackView = self.subviews.first as? ContainerStackView else { return nil }
        guard let button = stackView.subviews.compactMap({ $0 as? CallControlButton}).first(where: { $0.type == type}) else {
            return nil
        }
        return button
    }
}

public extension CallControlView {
    struct Content {
        var isAudioEnable: Bool
        var isVideoEnable: Bool
        var currentPort: AVAudioSession.Port
    }
}
