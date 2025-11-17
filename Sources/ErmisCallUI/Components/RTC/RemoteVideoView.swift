//
// Copyright 2025 Ermis Inc.
//

import UIKit
import AVFoundation
import ErmisCall

public class RemoteVideoView: VideoView {
    weak var previewLayer: AVSampleBufferDisplayLayer?

    public override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = videoView.bounds
    }

    public func attach(with player: ErmisPlayer) {
        self.previewLayer = player.videoLayer
        videoView.layer.addSublayer(player.videoLayer)
        previewLayer?.frame = videoView.bounds
    }
}

