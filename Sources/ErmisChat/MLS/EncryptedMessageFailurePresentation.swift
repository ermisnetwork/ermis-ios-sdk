// Copyright 2026 Ermis Inc.

import Foundation
import open_mls_ios

enum EncryptedMessageFailurePresentation {
    static func state(for error: Error, nativeAtExpectedEpoch: Bool) -> EncryptedMessageState {
        guard nativeAtExpectedEpoch else { return .encrypted }
        if let native = error as? MlsError {
            switch native {
            case .MessageAlreadyConsumed: return .unavailable
            case .InvalidMessage, .CryptoError, .DeserializationError: return .failed
            default: return .encrypted
            }
        }
        if error is E2eeMessageAADError || error is DecodingError { return .failed }
        return .encrypted
    }
}
