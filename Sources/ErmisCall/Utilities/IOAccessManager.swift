//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import AVFoundation

/// A class for access IO devices.
public class IOAccessManager {

    public init() {
        
    }
    // MARK: - Properties
    /// A boolean value `true` if camera souce is available on this device.
    public var isCameraAvailable: Bool {
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    /// A boolean value `true` if camera access permission is granted.
    public var isCameraAccessGranted: Bool {
        return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
    /// A boolean value `true` if microphone access permission is granted.
    public var isMicrophoneAccessGranted: Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    // MARK: - Public

    /// Request camera access permission if not granted
    ///
    ///  - Returns: A boolean value `true` if camera permission is granted.
    public func requestCameraAccessIfNeeded() async -> Bool {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorizationStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                self.requestCameraAccess(completion: { (granted) in
                    continuation.resume(returning: granted)
                })
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Request camera access permission if not granted
    ///
    ///  - Parameters:
    ///   - completion: A completion handler contain a boolean value `true` if camera access
    ///   permision is granted.
    public func requestCameraAccessIfNeeded(completion: @escaping (_ granted: Bool) -> Void) {

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch authorizationStatus {
        case .authorized:
            completion(true)
        case .notDetermined:
            self.requestCameraAccess(completion: { (granted) in
                completion(granted)
            })
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    /// Request microphone access permission if not granted
    ///
    ///  - Returns: A boolean value `true` if microphone permission is granted.
    public func requestMicrophoneAccessIfNeeded() async -> Bool {
        let authorizationStatus = AVAudioSession.sharedInstance().recordPermission
        switch authorizationStatus {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                self.requestMicrphoneAccess(completion: { (granted) in
                    continuation.resume(returning: granted)
                })
            }
        @unknown default:
            return false
        }
    }

    /// Request microphone access permission if not granted
    ///
    ///  - Parameters:
    ///   - completion: A completion handler contain a boolean value `true` if microphone access
    ///   permision is granted.
    public func requestMicrophoneAccessIfNeeded(completion: @escaping (_ granted: Bool) -> Void) {
        let authorizationStatus = AVAudioSession.sharedInstance().recordPermission
        switch authorizationStatus {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            self.requestMicrphoneAccess(completion: { (granted) in
                completion(granted)
            })
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Private
    private func requestCameraAccess(completion: @escaping (_ granted: Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    private func requestMicrphoneAccess(completion: @escaping (_ granted: Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}

