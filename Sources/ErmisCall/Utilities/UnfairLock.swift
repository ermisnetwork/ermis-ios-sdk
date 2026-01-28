//
// Copyright 2025 Ermis Inc.
//

import os

package class UnfairLock: @unchecked Sendable {
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    init() {
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    func lock() {
        os_unfair_lock_lock(lockPtr)
    }

    func unlock() {
        os_unfair_lock_unlock(lockPtr)
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
