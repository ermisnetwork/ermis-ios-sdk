import Foundation

public struct SessionSyncProgressSnapshot {
    public let cycleId: UUID
    public let phase: String
    public let status: String
    public let scheduled: Int
    public let completed: Int
}

/// Presentation only. Dismissal never cancels jobs; ownership changes retire callbacks.
public final class SessionSyncProgress {
    public static let changed = Notification.Name("io.ermis.session.sync.progress")
    struct Ticket { let session: UUID; let cycle: UUID; let work: UUID }
    private let lock = NSLock()
    private var session = UUID(), cycle = UUID()
    private var pending = Set<UUID>()
    private var scheduled = 0, completed = 0
    private var phase = "preparing", failed = false
    private var retryAction: (() -> Void)?
    private var value: SessionSyncProgressSnapshot?
    public var snapshot: SessionSyncProgressSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult func begin(_ phase: String) -> Ticket {
        lock.lock()
        if pending.isEmpty { cycle = UUID(); scheduled = 0; completed = 0; failed = false; retryAction = nil }
        let ticket = Ticket(session: session, cycle: cycle, work: UUID())
        pending.insert(ticket.work); scheduled += 1; self.phase = phase
        update(); let owner = session; lock.unlock(); publish(owner); return ticket
    }
    func phase(_ phase: String) { lock.lock(); guard !pending.isEmpty else { lock.unlock(); return }; self.phase = phase; update(); let owner = session; lock.unlock(); publish(owner) }
    func markPartial() { lock.lock(); guard !pending.isEmpty else { lock.unlock(); return }; failed = true; update(); let owner = session; lock.unlock(); publish(owner) }
    func end(_ ticket: Ticket, partial: Bool = false, retry: (() -> Void)? = nil) {
        lock.lock()
        guard ticket.session == session, ticket.cycle == cycle, pending.remove(ticket.work) != nil else { lock.unlock(); return }
        completed += 1; failed = failed || partial
        if let retry, failed { retryAction = retry }
        update(); let owner = session; lock.unlock(); publish(owner)
    }
    public func retry() { lock.lock(); let action = pending.isEmpty && failed ? retryAction : nil; lock.unlock(); action?() }
    func invalidate() { lock.lock(); session = UUID(); pending.removeAll(); value = nil; retryAction = nil; let owner = session; lock.unlock(); publish(owner) }
    private func update() { value = .init(cycleId: cycle, phase: phase, status: pending.isEmpty ? (failed ? "partial" : "done") : "running", scheduled: scheduled, completed: completed) }
    private func publish(_ owner: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.lock(); let current = owner == self.session; self.lock.unlock()
            if current { NotificationCenter.default.post(name: Self.changed, object: self) }
        }
    }
}
