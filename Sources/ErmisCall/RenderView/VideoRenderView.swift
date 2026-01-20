//
// Copyright 2025 Ermis Inc.
//

import AVFoundation
import UIKit

open class VideoRenderView: UIView {
    public weak var previewLayer: AVSampleBufferDisplayLayer?

    public override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    public func attach(with player: ErmisPlayer) {
        self.previewLayer = player.videoLayer
        layer.addSublayer(player.videoLayer)
        previewLayer?.frame = bounds
    }


}








