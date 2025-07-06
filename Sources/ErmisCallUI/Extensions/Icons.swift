//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat
import ErmisChatUI

public
extension Theme.Icons {
    private static func loadImageSafely(with imageName: String) -> UIImage {
        if let image = UIImage(named: imageName, in: .ermisCallUI) {
            return image
        } else {
            log.error(
                    """
                    \(imageName) image has failed to load from the bundle please make sure it's included in your assets folder.
                    A default asset image has been added.
                    """
            )
            return UIImage(systemName: "app")!
        }
    }

    private static func loadSafely(systemName: String, assetsFallback: String) -> UIImage {
        return UIImage(systemName: systemName) ?? loadImageSafely(with: assetsFallback)

    }

    // MARK: - Call Icons

    // Audio
    static var audioMuteOn = loadImageSafely(with: "ic_audio_mute_on")
    static var audioMuteOff = loadImageSafely(with: "ic_audio_mute_off")
    // Video
    static var videoMuteOn = loadImageSafely(with: "ic_video_mute_on")
    static var videoMuteOff = loadImageSafely(with: "ic_video_mute_off")
    // Camera
    static var cameraSwitch = loadImageSafely(with: "ic_camera_flip")
    // Speaker
    static var speakerExternal = loadImageSafely(with: "ic_speaker_external")
    static var speakerOff = loadImageSafely(with: "ic_speaker_off")
    static var speakerOn = loadImageSafely(with: "ic_speaker_on")

    static var chat = loadImageSafely(with: "ic_chat")
}
