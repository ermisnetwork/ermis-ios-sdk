import Foundation

/// Admission and continuation timing for the repository's existing refill owner.
/// Access is serialized by keyPackageRefillStateQueue; no timer or provider is owned here.
struct MlsKeyPackageRefillSchedule {
    private(set) var inFlight = false
    private var completedAtUptime: TimeInterval?

    mutating func begin(at uptime: TimeInterval) -> Bool {
        guard !inFlight,
              completedAtUptime.map({ uptime - $0 >= E2eeKeyPackageRefillPolicy.cooldown }) ?? true
        else { return false }
        inFlight = true
        return true
    }

    mutating func complete(at uptime: TimeInterval) {
        inFlight = false
        completedAtUptime = uptime
    }

    func wakeDelay(requestedAt: TimeInterval, wallTime: TimeInterval, uptime: TimeInterval) -> TimeInterval {
        max(30, requestedAt - wallTime,
            completedAtUptime.map { E2eeKeyPackageRefillPolicy.cooldown - (uptime - $0) } ?? 0)
    }
}
