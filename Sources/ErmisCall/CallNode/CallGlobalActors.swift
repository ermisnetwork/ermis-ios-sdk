//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Global actor for managing call state transitions
/// Use this actor for all call state updates to ensure they happen serially and safely
@globalActor
public actor CallActor {
    public static let shared = CallActor()
    
    private init() {}
}

/// Global actor for WebRTC/CallNode operations
/// Use this actor for media operations, connection management, etc.
@globalActor
public actor CallNodeActor {
    public static let shared = CallNodeActor()
    
    private init() {}
}
