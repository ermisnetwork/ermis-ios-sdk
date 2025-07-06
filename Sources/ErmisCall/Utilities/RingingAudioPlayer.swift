//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import AVFoundation
import ErmisChat

/// Audio player for playing ringing tone.
public class RingingAudioPlayer: NSObject {
    public static let shared = RingingAudioPlayer()
    static let vibrationInterval = 1.24875
    var audioPlayer: AVAudioPlayer?
    var isVibrating: Bool = false

    var vibrateCompletedBlock: AudioServicesSystemSoundCompletionProc = { systemSoundId,clientData in
        let ringingAudioPlayer = RingingAudioPlayer.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + RingingAudioPlayer.vibrationInterval) {
            if ringingAudioPlayer.isVibrating {
                ringingAudioPlayer.vibrate()
            } else {
                ringingAudioPlayer.stopVibrate()
            }
        }
    }

    public
    func playSound(at url: URL, vibrate: Bool, useBuiltInReceiver: Bool) {
        if audioPlayer != nil {
            self.stopPlaying(false)
        }
        self.audioPlayer = try? AVAudioPlayer(contentsOf: url)
        self.audioPlayer?.delegate = self
        self.audioPlayer?.numberOfLoops = -1
        audioPlayer?.prepareToPlay()

        if vibrate {
            self.vibrate()
        }
        self.audioPlayer?.play()
    }

    public
    func stopPlaying(_ shouldDeactiveAudioSession: Bool) {
        if let audioPlayer {
            audioPlayer.stop()
            self.audioPlayer = nil
        }

        if isVibrating {
            self.stopVibrate()
        }
    }

    func vibrate() {
        isVibrating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + RingingAudioPlayer.vibrationInterval, execute: {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            let objRepeat = NSNumber(booleanLiteral: true)
            AudioServicesAddSystemSoundCompletion(kSystemSoundID_Vibrate,
                                                  nil,
                                                  CFRunLoopMode.commonModes.rawValue,
                                                  self.vibrateCompletedBlock,
                                                  nil)
        })
    }

    func stopVibrate() {
        isVibrating = false
        AudioServicesRemoveSystemSoundCompletion(kSystemSoundID_Vibrate)
    }
}
// MARK: - AVAudioPlayerDelegate
extension RingingAudioPlayer: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.audioPlayer = nil
    }
}
