//
// Copyright 2025 Ermis Inc.
//

import StreamWebRTC

extension RTCAudioSessionConfiguration {
    static var `default`: RTCAudioSessionConfiguration {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        let categoryOptions: AVAudioSession.CategoryOptions = [
            .allowBluetooth,
            .allowBluetoothA2DP
        ]
        configuration.mode = AVAudioSession.Mode.videoChat.rawValue
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.categoryOptions = categoryOptions
        return configuration
    }
}

