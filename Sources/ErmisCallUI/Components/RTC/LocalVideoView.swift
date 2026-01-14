//
// Copyright 2025 Ermis Inc.
//

import UIKit
import AVFoundation
import ErmisCall

public class LocalVideoView: VideoView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    public override func setUp() {
        super.setUp()
    }

    public override func setUpUI() {
        super.setUpUI()

    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = videoView.frame
    }

    public func attach(with capturer: ErmisVideoCapturer) {
        previewLayer = AVCaptureVideoPreviewLayer(session: capturer.videoCaptureSession)
        videoView.layer.addSublayer(previewLayer!)
        previewLayer!.videoGravity = .resizeAspectFill
        previewLayer!.frame = videoView.bounds
    }
}
