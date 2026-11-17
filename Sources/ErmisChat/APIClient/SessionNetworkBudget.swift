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
    private let lock = NSLock()
    private var generation = UUID()
    private var active: [UUID: SessionNetworkPermit] = [:]
    private var waiting: [(run: (SessionNetworkPermit) -> Void, reject: () -> Void)] = []
    func captureOwner() -> () throws -> Void {
        lock.lock(); let owner = generation; lock.unlock()
        return { [weak self] in
            guard let self else { throw ClientError.Unexpected("request_owner_replaced") }
            self.lock.lock(); let current = self.generation; self.lock.unlock()
            guard owner == current else { throw ClientError.Unexpected("request_owner_replaced") }
        }
    }
    func submit(_ run: @escaping (SessionNetworkPermit) -> Void, reject: @escaping () -> Void) {
        lock.lock()
        if active.count < 2 { let permit = makePermit(); lock.unlock(); run(permit) }
        else if waiting.count < 256 { waiting.append((run, reject)); lock.unlock() }
        else { lock.unlock(); reject() }
    }
    private func makePermit() -> SessionNetworkPermit {
        let id = UUID(), permit = SessionNetworkPermit { [weak self] in self?.release(id) }
        active[id] = permit; return permit
    }
    private func release(_ id: UUID) {
        lock.lock(); active.removeValue(forKey: id)
        if !waiting.isEmpty {
            let next = waiting.removeFirst(), permit = makePermit(); lock.unlock()
            next.run(permit)
        } else { lock.unlock() }
    }
    func invalidate() {
        lock.lock(); generation = UUID(); let queued = waiting, running = Array(active.values); waiting.removeAll(); lock.unlock()
        queued.forEach { $0.reject() }; running.forEach { $0.cancel() }
    }
}
