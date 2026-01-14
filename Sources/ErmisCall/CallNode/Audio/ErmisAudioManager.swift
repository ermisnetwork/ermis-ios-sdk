//
// Copyright 2025 Ermis Inc.
//

import Foundation
import AVFoundation
import ErmisChat
import UIKit

/// A class for manage audio session
public class ErmisCallAudioManager {
    private let loudSpeakersIdentifier: String = "LOUD_SPEAKERS"
    private let loudSpeakersName: String = "Device Speaker"
    private let builtInIdentifier: String = "BUILT_IN"

    var isVideoCall: Bool = false
    var defaultPortType: AVAudioSession.Port = .builtInReceiver

    private let lock = NSRecursiveLock()
    public var isActive = false

    public var currentPort: AudioPort?

    public var allPort: [AudioPort] = [] {
        didSet {
            onPortsChange?()
        }
    }

    var onPortsChange: (() -> Void)?

    var hasExternalPort: Bool {
        return allPort.contains(where: { $0.isExternal })
    }

    private var isUpdatingAudioSession = false

    var isIncomingCall: Bool = false


    static let shared = ErmisCallAudioManager()

    init() {
//        allPort = getAllAudioPort()
        startObservingRouteChanges()
//        setDefaultPort()
    }

    deinit {
        stopObservingRouteChanges()
    }
    // MARK: - Setup

    func configureAudioSession(isIncomingCall: Bool, isVideoCall: Bool) {
        do {
            self.isVideoCall = isVideoCall
            self.isIncomingCall = isIncomingCall
            self.defaultPortType = isVideoCall ? .builtInSpeaker : .builtInReceiver
            self.configureAudioSession(isActive: !isIncomingCall)
        } catch {
            log.warning("[AudioManager] Config audio session failed: \(error)")
        }
    }

    private func configureAudioSession(isActive: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [
                                        .allowBluetooth,
                                        .allowBluetoothA2DP
                                    ])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            if isActive {
                try session.setActive(true)
            }
            log.debug("[AudioManager] configure audio session, isIncoming call: \(isIncomingCall)")
        } catch {
            log.warning("[AudioManager] Config audio session failed: \(error)")
        }
    }

    func updateAudioSessionConfigure() {
    }

    @objc
    private func routeChanged(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let changeReason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

//        log.debug("[AudioManager] 🔔 routeChanged: \(changeReason.rawValue) - \(changeReasonDescription(changeReason))")

        switch changeReason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
//            log.debug("[AudioManager] → Handling device change")
            allPort = getAllAudioPort()
            if isActive {
                setDefaultPort()
            }
        case .categoryChange:
//            log.debug("[AudioManager] → Handling category change, re-applying preferred route: \(AVAudioSession.sharedInstance().categoryOptions)")
            allPort = getAllAudioPort()
        default:
            break
        }
    }

    private func changeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown(\(reason.rawValue))"
        }
    }
    
    func isInputPort(port: AVAudioSessionPortDescription) -> Bool {
        if AVAudioSession.sharedInstance().availableInputs?.contains(port) == true {
            return true
        }
        return false
    }

    // MARK: - Public
    func didActivateAudioSession() {
        log.debug("[AudioManager] Did activated audio session.")
        do {
            let session = AVAudioSession.sharedInstance()

//            try session.setCategory(.playAndRecord,
//                                    mode: .voiceChat,
//                                    options: [
//                                        .allowBluetooth,
//                                        .allowBluetoothHFP,
//                                    ])
//            try session.setPreferredSampleRate(48_000)
//            try session.setActive(true)
            log.debug("[AudioManager] configure audio session, isIncoming call: \(isIncomingCall)")
            log.debug("[AudioManager] Did activate session: \(session.sampleRate), \(session.mode), \(session.category), \(session.categoryOptions)")

            let route = session.currentRoute
            for output in route.outputs {
                print("[AuidoManager]] Output:", output.portType.rawValue)
            }

            allPort = getAllAudioPort()

            isActive = true
            // Check if Bluetooth was already active before setting default
            setDefaultPort()
        } catch {
            log.warning("[AudioManager] Config audio session failed: \(error)")
        }

        log.debug("[AudioManager] DID ACTIVE AUDIO SESSION")
    }

    func didDeactivateAudioSession() {

    }

    @objc package func changeAudioPort(to portType: AVAudioSession.Port) {
        guard let port = allPort.first(where: { $0.portType == portType}) else {
            log.debug("[AudioManager] Change audio port failed, can not find expected port.")
            return
        }
        changeAudioPort(to: port)
        onPortsChange?()
    }

    func setDefaultPort() {
        log.debug("[AudioManager] set default port")
        if let wired = allPort.first(where: { $0.portType == .headphones}) {
            changeAudioPort(to: wired.portType)
        } else if let bluetooth = allPort.first(where: { $0.portType.isBlueTooth }) {
            changeAudioPort(to: bluetooth.portType)
        } else if let car = allPort.first(where: { $0.portType == .carAudio}) {
            changeAudioPort(to: car)
        } else if let defaultType = allPort.first(where: { $0.portType == defaultPortType}) {
            changeAudioPort(to: defaultType)
        } else if let buildIn = allPort.first(where: { $0.portType.isBuiltIn}) {
            changeAudioPort(to: buildIn)
        }
    }

    public func setOverrideOutputPort(isSpeaker: Bool) {
        do {
            if isSpeaker {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }
            let route = AVAudioSession.sharedInstance().currentRoute
            for output in route.outputs {
                print("[AudioManager] Output:", output.portType.rawValue)
            }
            log.debug("[AudioManager] set audio output port, isSpeaker: \(isSpeaker)")
        } catch {
            log.error("[AudioManager] Failed to set audio output port: \(error)")
        }
    }

    // MARK: - Private
    private func startObservingRouteChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: nil)
    }

    private func stopObservingRouteChanges() {
        NotificationCenter.default.removeObserver(self,
                                                  name: AVAudioSession.routeChangeNotification,
                                                  object: nil)
    }

    private func startObservingAudioSessionInterupt() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            switch type {
            case .began:
                log.debug("[AudioManager] Interruption began.")
            case .ended:
                log.debug("[AudioManager] Interruption ended.")
                // Check if should resume
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)

                if options.contains(.shouldResume) {
                    // RE-ACTIVATE YOUR MANUAL SESSION
                    //self.didActivateAudioSession()

                    // And restart WebRTC audio unit
                    self.isActive = true
                }

            @unknown default:
                break
            }
        }
    }

    private func changeAudioPort(to port: AudioPort) {
        currentPort = port
        let audioSession = AVAudioSession.sharedInstance()
        let isBuiltInReceiver = port.portType == .builtInReceiver

        guard isActive else {
            log.warning("[AudioManager] Ignore changing audio port because session is not active")
            return
        }

        do {
            if port.isExternal {
                // Use setPreferredInput for external input ports
                let preferredInput = audioSession.currentRoute.inputs.first(where: { $0.uid == port.port?.uid })
                try audioSession.setPreferredInput(preferredInput)
                try audioSession.overrideOutputAudioPort(.none)
                log.debug("[AudioManger] set preferred input: \(preferredInput)", subsystems: .call)
                // Do not change output override
            } else if port.portType == .builtInSpeaker {
                // Override output to speaker
                log.debug("[AudioManger] set override output to speaker", subsystems: .call)
                try audioSession.setPreferredInput(nil)
                try audioSession.overrideOutputAudioPort(.speaker)
                // Remove preferred input
            } else {
                // Default case: no override, remove preferred input
                log.debug("[AudioManger] default, not override anythings", subsystems: .call)
                try audioSession.setPreferredInput(nil)
                try audioSession.overrideOutputAudioPort(.none)
            }
            log.debug("[AudioManager] changeAudioPort(to port: \(port)")
        } catch {
            log.error("[AudioManager] Failed to set audio port: \(error)")
        }
    }
    // MARK: - Helper
    private func getAllAudioPort() -> [AudioPort] {
        var allPort = AVAudioSession.sharedInstance().currentRoute.outputs.map { port in
            AudioPort(withPort: port)
        }

        if !allPort.contains(where: { $0.portType == .builtInSpeaker}) {
            let builtInSpeaker = AudioPort(identifier: loudSpeakersIdentifier,
                                           name: loudSpeakersName,
                                           port: nil,
                                           portType: .builtInSpeaker)
            allPort.append(builtInSpeaker)
        }

        if !allPort.contains(where: { $0.portType == .builtInReceiver || $0.isExternal }), UIDevice.current.isPhone {
            let builtInReceiver = AudioPort(identifier: builtInIdentifier,
                                            name: UIDevice.current.localizedModel,
                                            port: nil,
                                            portType: .builtInReceiver)
            allPort.append(builtInReceiver)
        }

        allPort = allPort.sorted { port1, port2 in
            return port1.portType.rawValue < port2.portType.rawValue
        }

        return allPort
    }
}

