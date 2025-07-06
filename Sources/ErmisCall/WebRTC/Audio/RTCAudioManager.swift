//
// Copyright 2025 Ermis Inc.
//

import Foundation
import AVFoundation
import ErmisChat
import StreamWebRTC
import UIKit

/// A class for manage audio session
public class RTCAudioManager {
    private let loudSpeakersIdentifier: String = "LOUD_SPEAKERS"
    private let loudSpeakersName: String = "Device Speaker"
    private let builtInIdentifier: String = "BUILT_IN"

    private let audioQueue = DispatchQueue(label: "network.ermis.audioSession")

    var defaultPortType: AVAudioSession.Port = .builtInReceiver {
        didSet {
            setDefaultPort()
        }
    }

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

    init() {
        allPort = getAllAudioPort()
        startObservingRouteChanges()
        setDefaultPort()
    }

    deinit {
        stopObservingRouteChanges()
    }
    // MARK: - Setup

    func updateAudioSessionConfigure() {
        self.audioQueue.async { [weak self] in
            // prepare config
            let configuration = RTCAudioSessionConfiguration.webRTC()
            var categoryOptions: AVAudioSession.CategoryOptions = []
            configuration.category = AVAudioSession.Category.playAndRecord.rawValue
            configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
            if !(self?.currentPort?.isExternal ?? false) {
                categoryOptions = .init(rawValue: 0)
            } else {
                categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
            }
            if self?.currentPort?.portType == .builtInSpeaker {
                categoryOptions.insert(.defaultToSpeaker)
            }
            configuration.categoryOptions = categoryOptions

            // configure session
            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            // always unlock
            defer { session.unlockForConfiguration() }
            do {
                try session.overrideOutputAudioPort(self?.currentPort?.portType == .builtInSpeaker ? .speaker : .none)
                if self?.currentPort?.isExternal == true,
                   let port = self?.currentPort?.port {
                    try session.setPreferredInput(port)
                }
                try session.setConfiguration(configuration, active: true)
            } catch let error {
                log.debug("[Audio] change audio port failed with error: \(error)")
            }
        }
    }

    func setUseManualAudio(_ isUseManualAudio: Bool) {
        RTCAudioSession.sharedInstance().useManualAudio = isUseManualAudio
    }
    // MARK: - Public
    func activeAudioSession() throws {
        audioQueue.async {
            RTCAudioSession.sharedInstance().lockForConfiguration()
            try? RTCAudioSession.sharedInstance().setActive(true)
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            RTCAudioSession.sharedInstance().unlockForConfiguration()
        }
    }

    func deactiveAudioSession() throws {
        audioQueue.async {
            RTCAudioSession.sharedInstance().lockForConfiguration()
            try? RTCAudioSession.sharedInstance().overrideOutputAudioPort(.none)
            try? RTCAudioSession.sharedInstance().setActive(false)
            RTCAudioSession.sharedInstance().isAudioEnabled = false
            RTCAudioSession.sharedInstance().unlockForConfiguration()
        }
    }

    @objc package func changeAudioPort(to portType: AVAudioSession.Port) {
        guard let port = allPort.first(where: { $0.portType == portType}) else {
            return
        }
        changeAudioPort(to: port)
        onPortsChange?()
    }

    func setDefaultPort() {
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

    @objc
    private func routeChanged(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let changeReason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch changeReason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            allPort = getAllAudioPort()
            setDefaultPort()
        default:
            log.debug("[Audio] route changed with reason: \(changeReason)")
            break
        }
    }

    private func changeAudioPort(to port: AudioPort) {
        currentPort = port
        updateAudioSessionConfigure()
    }
    // MARK: - Helper
    private func getAllAudioPort() -> [AudioPort] {
        var allPort = RTCAudioSession.sharedInstance().currentRoute.outputs.map { port in
            AudioPort(withPort: port)
        }

        if !allPort.contains(where: { $0.portType == .builtInSpeaker}) {
            let builtInSpeaker = AudioPort(identifier: loudSpeakersIdentifier,
                                           name: loudSpeakersName,
                                           port: nil,
                                           portType: .builtInSpeaker)
            allPort.append(builtInSpeaker)
        }

        if !allPort.contains(where: { $0.portType == .builtInReceiver }), !UIDevice.current.isMac {
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


