//
// Copyright 2025 Ermis Inc.
//

import Foundation

public class ScheduledErmisTimer: ErmisTimer {
    let interval: TimeInterval
    var runLoop = RunLoop.current
    var timer: Foundation.Timer?
    public var onChange: (() -> Void)?

    public var isRunning: Bool {
        timer?.isValid ?? false
    }

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public func start() {
        stop()

        timer = Foundation.Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { _ in
            self.onChange?()
        }
        runLoop.add(timer!, forMode: .common)
        timer?.fire()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
