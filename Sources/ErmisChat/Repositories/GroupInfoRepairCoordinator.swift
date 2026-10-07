//
// Copyright 2026 Ermis Inc.
//

import Foundation

public extension Notification.Name {
    static let ermisGroupInfoRepairStateChanged = Notification.Name("io.ermis.groupInfoRepairStateChanged")
}

public enum GroupInfoRepairStatus: String {
    case refreshing
    case retryable
    case ready
    case removed
}

struct GroupInfoRepairScope: Codable, Equatable {
    let accountId: String
    let deviceId: String
}

struct StoredGroupInfoRefreshRequest: Codable, Equatable {
    let scope: GroupInfoRepairScope
    let cid: String
    let request: GroupInfoRefreshRequestPayload
}

protocol GroupInfoRepairStore {
    func load(scope: GroupInfoRepairScope) -> [StoredGroupInfoRefreshRequest]
    func upsert(_ record: StoredGroupInfoRefreshRequest)
    func remove(scope: GroupInfoRepairScope, cid: String, throughEpoch: Int?, requestId: String?)
}

final class UserDefaultsGroupInfoRepairStore: GroupInfoRepairStore {
    private let defaults: UserDefaults
    private let key = "io.ermis.groupInfoRepair.requests.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(scope: GroupInfoRepairScope) -> [StoredGroupInfoRefreshRequest] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().filter { $0.scope == scope }
    }

    func upsert(_ record: StoredGroupInfoRefreshRequest) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadAll().filter {
            !($0.scope == record.scope && $0.cid == record.cid && $0.request.requestId == record.request.requestId)
        }
        records.append(record)
        saveAll(records)
    }

    func remove(scope: GroupInfoRepairScope, cid: String, throughEpoch: Int?, requestId: String?) {
        lock.lock()
        defer { lock.unlock() }
        let records = loadAll().filter { record in
            guard record.scope == scope, record.cid == cid else { return true }
            let removeAll = throughEpoch == nil && requestId == nil
            let matchesRequest = requestId.map { $0 == record.request.requestId } ?? false
            let matchesEpoch = throughEpoch.map { record.request.minimumEpoch <= $0 } ?? false
            // An old ACK must not erase newer work with the same request ID.
            return !(throughEpoch != nil ? matchesEpoch : (removeAll || matchesRequest))
        }
        saveAll(records)
    }

    private func loadAll() -> [StoredGroupInfoRefreshRequest] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StoredGroupInfoRefreshRequest].self, from: data)) ?? []
    }

    private func saveAll(_ records: [StoredGroupInfoRefreshRequest]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

final class GroupInfoRepairCoordinator {
    static let maximumAttempts = 3
    private let store: GroupInfoRepairStore
    private let lock = NSLock()
    private var inFlightCids = Set<String>()
    var random: () -> Double = { Double.random(in: 0 ... 1) }
    var stateDidChange: (String, GroupInfoRepairStatus, TimeInterval?) -> Void

    init(
        store: GroupInfoRepairStore,
        stateDidChange: @escaping (String, GroupInfoRepairStatus, TimeInterval?) -> Void
    ) {
        self.store = store
        self.stateDidChange = stateDidChange
    }

    func pending(scope: GroupInfoRepairScope) -> [StoredGroupInfoRefreshRequest] {
        store.load(scope: scope)
    }

    func enqueue(
        scope: GroupInfoRepairScope,
        cid: String,
        request: GroupInfoRefreshRequestPayload
    ) -> Bool {
        store.upsert(.init(scope: scope, cid: cid, request: request))
        lock.lock()
        defer { lock.unlock() }
        guard !inFlightCids.contains(cid) else { return false }
        inFlightCids.insert(cid)
        stateDidChange(cid, .refreshing, nil)
        return true
    }

    func finish(cid: String) {
        lock.lock()
        inFlightCids.remove(cid)
        lock.unlock()
    }

    func clearUploaded(scope: GroupInfoRepairScope, cid: String, requestId: String, epoch: Int) {
        store.remove(scope: scope, cid: cid, throughEpoch: epoch, requestId: requestId)
        stateDidChange(cid, .ready, nil)
    }

    func clearRemoved(scope: GroupInfoRepairScope, cid: String) {
        store.remove(scope: scope, cid: cid, throughEpoch: nil, requestId: nil)
        finish(cid: cid)
        stateDidChange(cid, .removed, nil)
    }

    func retryDelay(attempt: Int) -> TimeInterval? {
        guard attempt < Self.maximumAttempts else { return nil }
        let base = min(2.0, 0.25 * pow(2.0, Double(attempt)))
        return base * (0.75 + random() * 0.5)
    }

    func emitRetryable(cid: String, delay: TimeInterval?) {
        stateDidChange(cid, .retryable, delay)
    }

    static func shouldClearAfterServerFailure(_ error: Error) -> Bool {
        let apiError: ErmisApiError?
        if let direct = error as? ErmisApiError {
            apiError = direct
        } else if let clientError = error as? ClientError {
            apiError = clientError.underlyingError as? ErmisApiError
        } else {
            apiError = nil
        }
        guard let status = apiError?.httpStatusCode else { return false }
        return status == 401 || status == 403 || status == 404
    }
}
