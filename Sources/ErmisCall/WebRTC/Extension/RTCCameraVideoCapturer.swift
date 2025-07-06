//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import StreamWebRTC

extension RTCCameraVideoCapturer {
    static
    func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = Self.captureDevices()
        guard let device = devices.first(where: { $0.position == position}) ?? devices.first else {
            log.warning("[Ermis Call] No camera video capture devices", subsystems: .webRTC)
            return nil
        }
        return device
    }
}

