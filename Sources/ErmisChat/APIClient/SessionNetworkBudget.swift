import Foundation

/// A permit remains held until URLSession finishes or confirms cancellation.
final class SessionNetworkPermit {
    private let lock = NSLock()
    private var releaseWork: (() -> Void)?
    private var cancellation: (() -> Void)?
    private var cancelled = false
    init(_ release: @escaping () -> Void) { releaseWork = release }
    func attachCancellation(_ work: @escaping () -> Void) {
        lock.lock(); cancellation = work; let cancel = cancelled; lock.unlock()
        if cancel { work() }
    }
    func cancel() { lock.lock(); cancelled = true; let work = cancellation; lock.unlock(); work?() }
    func release() {
        lock.lock(); let work = releaseWork; releaseWork = nil; cancellation = nil; lock.unlock(); work?()
    }
}

/// Per API/account HTTP budget, independent of the operation and auth-refresh queues.
final class SessionNetworkBudget {
    enum Priority: Equatable { case normal, metadata }
    private let lock = NSLock()
    private var generation = UUID()
    private var active: [UUID: SessionNetworkPermit] = [:]
    private var waiting: [(run: (SessionNetworkPermit) -> Void, priority: Priority, reject: () -> Void)] = []
    private var lastSelectionWasMetadata = false
    func captureOwner() -> () throws -> Void {
        lock.lock(); let owner = generation; lock.unlock()
        return { [weak self] in
            guard let self else { throw ClientError.Unexpected("request_owner_replaced") }
            self.lock.lock(); let current = self.generation; self.lock.unlock()
            guard owner == current else { throw ClientError.Unexpected("request_owner_replaced") }
        }
    }
    func submit(_ run: @escaping (SessionNetworkPermit) -> Void, priority: Priority = .normal,
                reject: @escaping () -> Void) {
        lock.lock()
        if active.count < 2 { let permit = makePermit(); lock.unlock(); run(permit) }
        else if waiting.count < 256 { waiting.append((run, priority, reject)); lock.unlock() }
        else { lock.unlock(); reject() }
    }
    private func makePermit() -> SessionNetworkPermit {
        let id = UUID(), permit = SessionNetworkPermit { [weak self] in self?.release(id) }
        active[id] = permit; return permit
    }
    private func release(_ id: UUID) {
        lock.lock(); active.removeValue(forKey: id)
        if !waiting.isEmpty {
            // Metadata can pass a background backlog, but at most one promotion
            // before the oldest normal request. FIFO within both lanes is intact.
            let preferred: Priority = lastSelectionWasMetadata ? .normal : .metadata
            let index = waiting.firstIndex { $0.priority == preferred } ?? 0
            let next = waiting.remove(at: index), permit = makePermit()
            lastSelectionWasMetadata = next.priority == .metadata
            lock.unlock()
            next.run(permit)
        } else { lock.unlock() }
    }
    func invalidate() {
        lock.lock(); generation = UUID(); let queued = waiting, running = Array(active.values); waiting.removeAll(); lastSelectionWasMetadata = false; lock.unlock()
        queued.forEach { $0.reject() }; running.forEach { $0.cancel() }
    }
}
