//
// Copyright 2025 Ermis Inc.
//

import UIKit

public struct CallComponents {
    public static var `default` = Self()
    /// The view controller for showing call.
    public var callVC: CallViewController.Type = CallViewController.self
    /// The navigation titleview of CallViewController.
    public var callTitleContainerView: CallTitleContainerView.Type = CallTitleContainerView.self
    /// The video view that render user's video.
    public var videoView: VideoView.Type = VideoView.self
    /// The view show connection status when the connection has problem.
    public var connectionStatusView: CallConnectionStatusView.Type = CallConnectionStatusView.self
    /// The view show control buttons.
    public var controlsView: CallControlView.Type = CallControlView.self
    /// The view show control button.
    public var controlButton: CallControlButton.Type = CallControlButton.self
}

public protocol CallComponentsProvider: AnyObject {
    var callComponents: CallComponents { get set }
}

public extension CallComponentsProvider where Self: UIResponder {
    var callComponents: CallComponents {
        get {
            return CallComponents.default
        }

        set {
            CallComponents.default = newValue
        }
    }
}
