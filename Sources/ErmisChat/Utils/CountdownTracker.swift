//
// Copyright 2025 Ermis Inc.
//

import Foundation

public class CooldownTracker {
    private var timer: ErmisTimer

    public var onChange: ((Int) -> Void)?

    public init(timer: ErmisTimer) {
        self.timer = timer
    }

    public func start(with cooldown: Int) {
        guard cooldown > 0 else { return }

        var duration = cooldown

        timer.onChange = { [weak self] in
            self?.onChange?(duration)

            if duration == 0 {
                self?.timer.stop()
            } else {
                duration -= 1
            }
        }

        timer.start()
    }

    public func stop() {
        guard timer.isRunning else { return }

        timer.stop()
    }

    deinit {
        stop()
    }
}
