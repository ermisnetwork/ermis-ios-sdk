//
// Copyright 2025 Ermis Inc.
//

import Foundation

public protocol ErmisTimer {
    func start()
    func stop()
    var onChange: (() -> Void)? { get set }
    var isRunning: Bool { get }
}
