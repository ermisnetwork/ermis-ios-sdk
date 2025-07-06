//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// This is a protocol describing an audio recording delegate
public protocol AudioRecordingDelegate: AnyObject {
    /// Notifies the delegate that the audio recording's context was updated.
    func audioRecorder(_ audioRecorder: AudioRecording, didUpdateContext: AudioRecordingContext)

    /// Notifies the delegate that the audio recording finished at the specified URL.
    func audioRecorder(_ audioRecorder: AudioRecording, didFinishRecordingAtURL: URL)

    /// Notifies the delegate that the audio recording failed with an error.
    func audioRecorder(_ audioRecorder: AudioRecording, didFailWithError: Error)
}
