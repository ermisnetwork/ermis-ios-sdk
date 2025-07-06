//
// Copyright 2025 Ermis Inc.
//

import Foundation
import AVFAudio

public
struct AudioPort: Equatable {
    public var identifier: String
    public var name: String
    public var port: AVAudioSessionPortDescription?
    public var portType: AVAudioSession.Port

    init(identifier: String,
         name: String,
         port: AVAudioSessionPortDescription?,
         portType: AVAudioSession.Port) {
        self.identifier = identifier
        self.name = name
        self.port = port
        self.portType = portType
    }

    init(withPort port: AVAudioSessionPortDescription) {
        self.init(identifier: port.uid, name: port.portName, port: port, portType: port.portType)
    }

    public var isExternal: Bool {
        switch portType {
        case .builtInMic, .builtInSpeaker, .builtInReceiver:
            return false
        default:
            return true
        }
    }
}

