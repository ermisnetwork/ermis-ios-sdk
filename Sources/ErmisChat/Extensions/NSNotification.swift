//
// Copyright 2025 Ermis Inc.
//

import Foundation

public extension NSNotification.Name {
    /// Send went callvc is hidden but the call is still ongoing.
    static let callVCDidHidden = Self("network.ermis.ermisChat.callVCDidHidden")
    /// Send went call was ended.
    static let callDidEnded = Self("network.ermis.ermisChat.callDidEnded")
    /// Send went tap on ongoing call view to resume call.
    static let ongoingCallViewDidTap = Self("network.ermis.ermisChat.ongoingCallViewDidTap")
}
