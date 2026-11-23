import Foundation

public struct SessionSyncProgressSnapshot {
    public let cycleId: UUID
    public let phase: String
    public let status: String
    // Legacy page/sync work counters. These never establish channel readiness.
    public let scheduled: Int
    public let completed: Int
    public let isChannelReadiness: Bool
    public let totalChannels: Int?
    public let readyChannels: Int
    public let blockedChannels: Int
    public let failedChannels: Int
    public let settledScopes: Int
    public let totalScopes: Int
    public let standardChannels: Int
}

/// One session's presentation state. Jobs and verified channel readiness have separate units.
/// Dismissal never cancels work. All inventory/readiness callbacks carry their original owner.
public final class SessionSyncProgress {
    public static let changed = Notification.Name("io.ermis.session.sync.progress")
    struct Ticket { let session: UUID; let cycle: UUID; let work: UUID }
    struct InventoryTicket: Equatable { let session: UUID; let work: UUID }
    enum ScopeResult: Equatable { case pending, ready, blocked, failed }

    private let lock = NSLock()
    private var session = UUID(), cycle = UUID()
    private var pending = Set<UUID>()
    private var scheduled = 0, completed = 0
    private var phase = "preparing", failed = false
    private var retryAction: (() -> Void)?
    private var value: SessionSyncProgressSnapshot?
    private var quietRestoredBootstrap = false
    private var historyPresentation = false
    private var historyTickets = Set<UUID>()

    private var inventoryRequest: InventoryTicket?
    private var excludedDuringInventory = Set<String>()
    private var inventoryCycle: UUID?
    private var channels: [String: String]?
    private var weights: [String: Int] = [:]
    private var channelsByScope: [String: Set<String>] = [:]
    private var results: [String: ScopeResult] = [:]
    private var ready = 0, blocked = 0, failures = 0, settled = 0
    private var standardCount = 0, standardSettled = 0
    private var inventoryFailed = false
    private var readinessStarted = false
    private var inventoryRetry: (() -> Void)?
    private var started = ProcessInfo.processInfo.systemUptime

    public var snapshot: SessionSyncProgressSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
    var owner: UUID { lock.lock(); defer { lock.unlock() }; return session }
    var hasPendingWork: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }
    var isInventoryBootstrapDeferred: Bool {
        lock.lock(); defer { lock.unlock() }
        return inventoryRequest != nil || inventoryFailed || (inventoryCycle != nil && channels == nil)
    }
    func owns(_ owner: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return session == owner }

    func deferRestoredBootstrapPresentation() {
        lock.lock(); defer { lock.unlock() }
        if channels == nil { quietRestoredBootstrap = true }
    }

    /// Historical bootstrap completion only; runtime guards remain in E2eRepository.
    func restoreBootstrapMilestones(_ scopes: Set<String>, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard owner == session else { return }
        for scope in scopes where results[scope] == nil { results[scope] = .ready }
    }

    /// Reserve before the root request, but do not publish a denominator from its first page.
    func beginInventory() -> InventoryTicket? {
        lock.lock()
        guard inventoryRequest == nil else { lock.unlock(); return nil }
        let ticket = InventoryTicket(session: session, work: UUID())
        inventoryRequest = ticket
        excludedDuringInventory.removeAll()
        inventoryFailed = false
        if inventoryCycle == nil { inventoryCycle = UUID(); started = ProcessInfo.processInfo.systemUptime }
        update(); let owner = session; lock.unlock(); publish(owner)
        return ticket
    }

    func owns(_ ticket: InventoryTicket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket.session == session && inventoryRequest == ticket
    }

    /// O(C + S) only at an authoritative inventory boundary. Unchanged snapshots keep the cycle.
    func finishInventory(_ ticket: InventoryTicket, channels inventory: [String: String], retry: @escaping () -> Void) {
        lock.lock()
        guard ticket.session == session, inventoryRequest == ticket else { lock.unlock(); return }
        let inventory = inventory.filter { !excludedDuringInventory.contains($0.key) }
        excludedDuringInventory.removeAll()
        inventoryRequest = nil; inventoryFailed = false; inventoryRetry = retry
        if let previous = channels, previous != inventory { inventoryCycle = UUID(); started = ProcessInfo.processInfo.systemUptime }
        channels = inventory
        weights = inventory.reduce(into: [:]) { $0[$1.value, default: 0] += 1 }
        channelsByScope = inventory.reduce(into: [:]) { $0[$1.value, default: []].insert($1.key) }
        ready = 0; blocked = 0; failures = 0; settled = 0; standardSettled = 0
        standardCount = weights.keys.filter { $0.hasPrefix("standard|") }.count
        for (scope, weight) in weights { add(results[scope] ?? .pending, weight: weight, sign: 1, standard: scope.hasPrefix("standard|")) }
        historyPresentation = false
        update(); let owner = session; lock.unlock(); publish(owner)
    }

    func failInventory(_ ticket: InventoryTicket, retry: @escaping () -> Void) {
        lock.lock()
        guard ticket.session == session, inventoryRequest == ticket else { lock.unlock(); return }
        inventoryRequest = nil; inventoryFailed = true; inventoryRetry = retry
        update(); let owner = session; lock.unlock(); publish(owner)
    }

    /// Session catch-up starts after serial preparation; point opens never call this.
    func startReadiness(owner: UUID) {
        lock.lock()
        guard owner == session, !readinessStarted else { lock.unlock(); return }
        readinessStarted = true
        update(); lock.unlock(); publish(owner)
    }

    /// O(1) weighted transition, including topics sharing a parent. Job completion never calls this.
    func record(scope: String, result: ScopeResult, owner: UUID, invalidateReady: Bool = false) {
        lock.lock()
        guard owner == session else { lock.unlock(); return }
        let old = results[scope] ?? .pending
        // An in-flight restore/sync callback cannot revoke an already verified Ready milestone.
        guard old != result, !(old == .ready && result == .pending && !invalidateReady) else { lock.unlock(); return }
        results[scope] = result
        if historyTickets.isEmpty { historyPresentation = false }
        if let weight = weights[scope] {
            // A genuine new terminal failure after Ready starts a revised cycle; it is never
            // hidden by a sticky success count. Old owners are rejected above.
            if old == .ready { inventoryCycle = UUID(); started = ProcessInfo.processInfo.systemUptime }
            add(old, weight: weight, sign: -1, standard: scope.hasPrefix("standard|")); add(result, weight: weight, sign: 1, standard: scope.hasPrefix("standard|"))
        }
        update(); lock.unlock(); publish(owner)
    }

    var incompleteScopes: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(weights.keys.filter { results[$0] != .ready })
    }

    func installInventoryRetry(owner: UUID, _ action: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if session == owner { inventoryRetry = action }
    }

    func excludeChannel(_ cid: String, owner: UUID) { exclude([cid], owner: owner) }
    func excludeChannels(_ ids: Set<String>, owner: UUID) { exclude(ids, owner: owner) }
    func excludeScope(_ scope: String, owner: UUID) {
        lock.lock(); let ids = channelsByScope[scope] ?? []; lock.unlock()
        exclude(ids, owner: owner)
    }
    /// A known removal revises eligibility, never a success count. O(affected channels).
    private func exclude(_ ids: Set<String>, owner: UUID) {
        lock.lock()
        guard owner == session else { lock.unlock(); return }
        var changed = false
        for cid in ids {
            if inventoryRequest != nil { excludedDuringInventory.insert(cid) }
            guard let scope = channels?.removeValue(forKey: cid), let weight = weights[scope] else { continue }
            changed = true
            let result = results[scope] ?? .pending
            switch result {
            case .ready: ready -= 1
            case .blocked: blocked -= 1
            case .failed: failures -= 1
            case .pending: break
            }
            channelsByScope[scope]?.remove(cid)
            if weight == 1 {
                weights.removeValue(forKey: scope); channelsByScope.removeValue(forKey: scope)
                if result != .pending { settled -= 1; if scope.hasPrefix("standard|") { standardSettled -= 1 } }
                if scope.hasPrefix("standard|") { standardCount -= 1 }
                results[scope] = .blocked
            } else { weights[scope] = weight - 1 }
        }
        guard changed else { lock.unlock(); return }
        inventoryCycle = UUID(); started = ProcessInfo.processInfo.systemUptime
        update(); lock.unlock(); publish(owner)
    }

    private func add(_ result: ScopeResult, weight: Int, sign: Int, standard: Bool = false) {
        if standard && result != .pending { standardSettled += sign }
        switch result {
        case .pending: break
        case .ready: ready += sign * weight; settled += sign
        case .blocked: blocked += sign * weight; settled += sign
        case .failed: failures += sign * weight; settled += sign
        }
    }

    @discardableResult func begin(_ phase: String) -> Ticket {
        lock.lock()
        if pending.isEmpty { cycle = UUID(); scheduled = 0; completed = 0; failed = false; retryAction = nil }
        let ticket = Ticket(session: session, cycle: cycle, work: UUID())
        pending.insert(ticket.work); scheduled += 1; self.phase = phase
        if phase == "restoring_page" { historyPresentation = true; historyTickets.insert(ticket.work) }
        else if historyTickets.isEmpty { historyPresentation = false }
        update(); let owner = session; lock.unlock(); publish(owner); return ticket
    }
    func phase(_ phase: String) { lock.lock(); guard !pending.isEmpty else { lock.unlock(); return }; if !historyPresentation { self.phase = phase }; update(); let owner = session; lock.unlock(); publish(owner) }
    func markPartial() { lock.lock(); guard !pending.isEmpty else { lock.unlock(); return }; failed = true; update(); let owner = session; lock.unlock(); publish(owner) }
    func end(_ ticket: Ticket, partial: Bool = false, retry: (() -> Void)? = nil) {
        lock.lock()
        guard ticket.session == session, ticket.cycle == cycle, pending.remove(ticket.work) != nil else { lock.unlock(); return }
        completed += 1; failed = failed || partial
        historyTickets.remove(ticket.work)
        // A settled page must not hide an existing session inventory indefinitely.
        if historyTickets.isEmpty, inventoryCycle != nil { historyPresentation = false }
        if let retry, failed { retryAction = retry }
        update(); let owner = session; lock.unlock(); publish(owner)
    }
    public func retry() {
        lock.lock()
        let action: (() -> Void)?
        if value?.isChannelReadiness == true {
            action = value?.status == "partial" && inventoryRequest == nil ? inventoryRetry : nil
            // Single consumption; the existing retry path installs the next bounded action.
            if action != nil { inventoryRetry = nil }
        } else { action = pending.isEmpty && failed ? retryAction : nil }
        lock.unlock(); action?()
    }
    func invalidate() {
        lock.lock(); session = UUID(); pending.removeAll(); value = nil; retryAction = nil
        quietRestoredBootstrap = false
        readinessStarted = false
        inventoryRequest = nil; inventoryCycle = nil; channels = nil; weights.removeAll(); channelsByScope.removeAll(); results.removeAll(); historyTickets.removeAll()
        excludedDuringInventory.removeAll()
        ready = 0; blocked = 0; failures = 0; settled = 0; standardCount = 0; standardSettled = 0; inventoryFailed = false; inventoryRetry = nil; historyPresentation = false
        let owner = session; lock.unlock(); publish(owner)
    }
    private func update() {
        if let inventoryCycle, !historyPresentation {
            let total = channels?.count
            if quietRestoredBootstrap && !inventoryFailed && (total == nil || ready == total) {
                value = nil
                return
            }
            if total != nil { quietRestoredBootstrap = false }
            // Refreshing metadata does not erase the committed cycle's readiness
            // presentation. Only the first inventory has an unknown denominator.
            let status = inventoryFailed ? "partial" : total == nil ? "running" : ready == total ? "done" : settled == weights.count ? "partial" : "running"
            value = .init(cycleId: inventoryCycle, phase: total == nil ? "inventory" : status == "running" && !readinessStarted ? "preparing" : "readiness", status: status,
                scheduled: scheduled, completed: completed, isChannelReadiness: true, totalChannels: total,
                readyChannels: ready, blockedChannels: blocked, failedChannels: failures, settledScopes: settled - standardSettled, totalScopes: weights.count - standardCount, standardChannels: standardCount)
        } else {
            value = .init(cycleId: cycle, phase: phase, status: pending.isEmpty ? (failed ? "partial" : "done") : "running",
                scheduled: scheduled, completed: completed, isChannelReadiness: false, totalChannels: nil,
                readyChannels: 0, blockedChannels: 0, failedChannels: 0, settledScopes: 0, totalScopes: 0, standardChannels: 0)
        }
    }
    private func publish(_ owner: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.lock()
            let current = owner == self.session, state = self.value
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - self.started) * 1000)
            self.lock.unlock()
            if current {
                if let state, state.isChannelReadiness {
                    log.info("session_readiness cycle=\(state.cycleId.uuidString.lowercased()) status=\(state.status) total=\(state.totalChannels ?? -1) ready=\(state.readyChannels) blocked=\(state.blockedChannels) failed=\(state.failedChannels) settled=\(state.settledScopes) scopes=\(state.totalScopes) elapsed_ms=\(elapsed)", subsystems: .mls)
                }
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
    }
}
