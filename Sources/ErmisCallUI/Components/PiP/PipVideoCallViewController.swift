//
// Copyright 2025 Ermis Inc.
//

import AVKit
import UIKit
import ErmisChat

open class PiPVideoCallViewController: AVPictureInPictureVideoCallViewController {

    // MARK: - Properties

    // Keep weak reference to avoid retain cycle
    weak var videoLayer: AVSampleBufferDisplayLayer?

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer?.frame = view.bounds
    }

    // MARK: - Public Methods

    func attachVideoLayer(_ layer: AVSampleBufferDisplayLayer) {
        // Remove old layer if exists
        videoLayer?.removeFromSuperlayer()
        // Store reference
        videoLayer = layer

        // Configure layer
        layer.videoGravity = .resizeAspectFill

        // Add to view
        view.layer.addSublayer(layer)
    }

    func detachVideoLayer() {
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
    }
}

