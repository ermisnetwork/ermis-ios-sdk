//
// Copyright 2025 Ermis Inc.
//

import AVKit
import ErmisChat
import UIKit

/// A view that shows a playing video content.
@objc(ErmisPlayerView)
open class PlayerView: _View {
    /// A player this view is following.
    open private(set) lazy var player = AVPlayer()

    override open func setUp() {
        super.setUp()

        playerLayer?.player = player
    }

    public var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }

    override public static var layerClass: AnyClass {
        AVPlayerLayer.self
    }
}
