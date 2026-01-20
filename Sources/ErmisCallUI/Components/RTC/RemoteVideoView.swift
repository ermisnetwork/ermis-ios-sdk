//
// Copyright 2025 Ermis Inc.
//

import UIKit
import AVFoundation
import ErmisCall

public class RemoteVideoView: VideoView {
    weak var renderView: VideoRenderView?

    public override func layoutSubviews() {
        super.layoutSubviews()
        renderView?.previewLayer?.frame = videoView.bounds
    }

    public func attach(with renderView: VideoRenderView) {
        if self.renderView != nil {
            self.renderView?.removeFromSuperview()
        }

        if renderView.superview != nil {
            self.renderView?.removeFromSuperview()
        }
        
        self.renderView = renderView
        videoView.embed(renderView)
    }
}

