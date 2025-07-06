//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import ErmisChatUI
/// A control button.
open class CallControlButton: _Button, UIProvider {
    public var type: CallControlButtonType = .speaker {
        didSet { updateContentIfNeeded() }
    }
    /// A boolean value `true` if current control is enable.
    public var enableState: Bool = true {
        didSet {
            updateContentIfNeeded()
        }
    }
    /// Callback for action selected.
    public var didTap: (() -> Void)?

    required public init(type: CallControlButtonType) {
        super.init(frame: .zero)
        self.type = type
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        self.type = .speaker
    }
    
    // MARK: - Overrides

    public var defaultIntrinsicContentSize = CGSize(width: 48, height: 48)

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    public func setEnableState(_ isEnable: Bool) {
        self.enableState = isEnable
        contentDidChanged()
    }

    override open var intrinsicContentSize: CGSize {
        defaultIntrinsicContentSize
    }

    override open func setUpTheme() {
        super.setUpTheme()
        titleLabel?.font = theme.fonts.body
        tintColor = tintColor(for: type)
        backgroundColor = backgroundColor(for: type)
    }

    override open func setUp() {
        super.setUp()
        addTarget(self, action: #selector(handleTouchUpInside), for: .touchUpInside)
    }

    public override func setUpUI() {
        super.setUpUI()
    }

    override open func contentDidChanged() {
        super.contentDidChanged()
        setImage(enableState ? enableImage(for: type) :
                    disableImage(for: type),
                 for: .normal)

    }
    /// Get tint color of control button.
    ///
    ///  - Parameters:
    ///    - type: type of control button.
    ///
    ///   - Returns: Tint color of control button.
    open func tintColor(for type: CallControlButtonType) -> UIColor {
        switch type {
        case .endCall:
            return theme.colors.error
        default:
            return theme.colors.white
        }
    }

    /// Get background color of control button.
    ///
    ///  - Parameters:
    ///    - type: type of control button.
    ///
    ///   - Returns: Background color of control button.
    open func backgroundColor(for type: CallControlButtonType) -> UIColor {
        theme.colors.white.withAlphaComponent(0.3)
    }

    /// Get image of control button when it's state is enable.
    ///
    ///  - Parameters:
    ///    - type: type of control button.
    ///
    ///   - Returns: Image of control button when it's state is enable.
    open func enableImage(for type: CallControlButtonType) -> UIImage? {
        switch type {
        case .speaker:
            return UIImage(systemName: "speaker.wave.3.fill")!
        case .video:
            return UIImage(systemName: "video.fill")!
        case .switchCamera:
            return Theme.Icons.cameraSwitch
        case .mic:
            return UIImage(systemName: "mic.fill")!
        case .endCall:
            return UIImage(systemName: "xmark")!
        case .shareScreen:
            return UIImage(systemName: "display.2")!
        case .custom:
            // Define in subclass
            return nil
        }
    }

    /// Get image of control button when it's state is disable.
    ///
    ///  - Parameters:
    ///    - type: type of control button.
    ///
    ///   - Returns: Image of control button when it's state is disable.
    open func disableImage(for type: CallControlButtonType) -> UIImage? {
        switch type {
        case .speaker:
            return UIImage(systemName: "speaker.wave.1.fill")!
        case .video:
            return UIImage(systemName: "video.slash.fill")!
        case .switchCamera:
            return Theme.Icons.cameraSwitch
        case .mic:
            return UIImage(systemName: "mic.slash.fill")!
        case .endCall:
            return UIImage(systemName: "xmark")!
        case .shareScreen:
            return UIImage(systemName: "display.2")!
        case .custom:
            // Define in subclass
            return nil
        }
    }

    // MARK: - Actions

    @objc open func handleTouchUpInside() {
        didTap?()
    }
}

public enum CallControlButtonType: Equatable {
    case speaker
    case video
    case switchCamera
    case mic
    case endCall
    case shareScreen
    case custom(rawValue: String)

    public static func == (lhs: CallControlButtonType, rhs: CallControlButtonType) -> Bool {
        switch (lhs, rhs) {
        case (.speaker, .speaker),
            (.video, .video),
            (.switchCamera, .switchCamera),
            (.mic, .mic),
            (.endCall, .endCall):
            return true
        case (.custom(let lRawValue), .custom(rawValue: let rRawvalue)):
            return lRawValue == rRawvalue
        default:
            return false
        }
    }
}
