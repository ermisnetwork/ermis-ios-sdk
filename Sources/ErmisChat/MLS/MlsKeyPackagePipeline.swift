import Foundation
import open_mls_ios

/// One bounded owner for inventory → read-only probe → retirement → durable batch → count.
/// Queue serializes public work only; MLS execution is entered for short local probes/generation.
final class MlsKeyPackagePipeline {
    private let api: APIClient
    private let store: MlsKeyPackageWorkStore
    private let assertOwner: () throws -> Void
    private let probe: ([Data]) throws -> [Bool]
    private let generate: (String, String, Int) throws -> [(Data, Data)]
    private let providerId: () throws -> String
    private let recover: (String) throws -> [(Data, Data)]?
    private let queue = DispatchQueue(label: "network.ermis.key-package-work")
    private let completion: (TimeInterval) -> Void
    private var state: MlsKeyPackageWork
    private let now: () -> Date
    private let started: Date
    private let operationId = UUID().uuidString
    private var finished = false
    private var deadline: Date { started.addingTimeInterval(30) }
    init(api: APIClient, store: MlsKeyPackageWorkStore, assertOwner: @escaping () throws -> Void,
         probe: @escaping ([Data]) throws -> [Bool], providerId: @escaping () throws -> String,
         generate: @escaping (String, String, Int) throws -> [(Data, Data)],
         recover: @escaping (String) throws -> [(Data, Data)]? = { _ in nil },
         now: @escaping () -> Date = Date.init, completion: @escaping (TimeInterval) -> Void) throws {
        self.api = api; self.store = store; self.assertOwner = assertOwner; self.probe = probe
        self.generate = generate; self.recover = recover; self.providerId = providerId; self.now = now; self.started = now(); self.completion = completion; state = try store.read()
    }
    func start(reason: String) {
        queue.async {
            do {
                try self.current()
                guard self.state.leaseUntil <= self.started.timeIntervalSince1970 else { self.finish(); return }
                var next = self.state; next.leaseId = self.operationId; next.leaseUntil = self.deadline.timeIntervalSince1970
                try self.save(next)
                self.queue.asyncAfter(deadline: .now() + 30) { self.finish() }
                self.ownership(slot: 0, reason: reason)
            } catch { self.finish() }
        }
    }
    private func current() throws {
        try assertOwner()
        guard !finished, now() >= started, now() < deadline else { throw ClientError.Unexpected("key_package_operation_expired") }
    }
    private func save(_ next: MlsKeyPackageWork) throws { try current(); state = try store.write(expected: state, next: next) }
    private func request<R>(_ endpoint: Endpoint<R>, _ done: @escaping (Result<R, Error>) -> Void) {
        do { try current() } catch { finish(); return }
        let scoped = endpoint.scopedMls(deadline: deadline) { [weak self] in
            guard let self else { throw ClientError.Unexpected("key_package_owner_gone") }; try self.current()
        }
        api.request(endpoint: scoped) { result in
            self.queue.async { do { try self.current(); done(result) } catch { self.finish() } }
        }
    }
    private func ownership(slot: Int, reason: String) {
        do {
            try current()
            guard slot < 3 else { refill(reason: reason, remaining: 5); return }
            let now = self.now().timeIntervalSince1970
            let index = slot == 0 ? state.retries.firstIndex(where: { $0.retryAt <= now }) : nil
            let retry = index.map { state.retries[$0] }
            if retry == nil, state.retryAt > now { refill(reason: reason, remaining: 5); return }
            let cursor = retry != nil ? retry?.cursor : state.cursor
            let attempts = min(1_000_000, (retry?.attempts ?? state.attempts) + 1)
            let due = MlsKeyPackageWorkStore.retryAt(now: now, attempts: attempts)
            var reserved = state
            if let index { reserved.retries[index].attempts = attempts; reserved.retries[index].retryAt = due }
            else { reserved.attempts = attempts; reserved.retryAt = due }
            try save(reserved)
            request(.keyPackageOwnership(cursor)) { result in
                do {
                    let page: MlsOwnershipInventory
                    switch result {
                    case let .success(value): page = value
                    case let .failure(error):
                        let apiError = error as? ErmisApiError ?? (error as? ClientError)?.underlyingError as? ErmisApiError
                        if let status = apiError?.httpStatusCode, [404, 405, 501].contains(status) { self.refill(reason: reason, remaining: 5) }
                        else if retry != nil { self.ownership(slot: slot + 1, reason: reason) } else { self.finish() }
                        return
                    }
                    try self.validate(page, after: cursor)
                    let owned = try self.probe(page.entries.map { $0.key_package_ref })
                    guard owned.count == page.entries.count else { throw ClientError.Unexpected("key_package_probe_uncertain") }
                    let missing = zip(page.entries, owned).filter { !$0.1 }.map { MlsOwnershipMissing(id: $0.0.id, key_package_ref: $0.0.key_package_ref) }
                    let completePage: (Bool) -> Void = { partial in
                        do {
                            _ = try self.probe(page.entries.map { $0.key_package_ref }); try self.current()
                            var next = self.state
                            if let index { if !partial { next.retries.remove(at: index) } }
                            else if !partial { next.cursor = page.next_cursor; next.attempts = 0; next.retryAt = 0 }
                            else if attempts >= 3, next.retries.count < 16 {
                                if !next.retries.contains(where: { $0.cursor == cursor }) { next.retries.append(.init(cursor: cursor, attempts: attempts, retryAt: due)) }
                                next.cursor = page.next_cursor; next.attempts = 0; next.retryAt = 0
                            }
                            try self.save(next)
                            if retry == nil, page.next_cursor == nil, !partial { self.refill(reason: reason, remaining: 5) }
                            else { self.ownership(slot: slot + 1, reason: reason) }
                        } catch { self.finish() }
                    }
                    if missing.isEmpty { completePage(false); return }
                    guard try self.probe(missing.map { $0.key_package_ref }).allSatisfy({ !$0 }) else { throw ClientError.Unexpected("key_package_private_changed") }
                    self.request(.retireKeyPackageOwnership(missing)) { result in
                        switch result {
                        case let .success(retired):
                            guard (0...missing.count).contains(retired.retired) else { self.finish(); return }; completePage(retired.retired < missing.count)
                        case .failure:
                            if retry != nil { self.ownership(slot: slot + 1, reason: reason) } else { self.finish() }
                        }
                    }
                } catch { self.finish() }
            }
        } catch { finish() }
    }
    private func validate(_ page: MlsOwnershipInventory, after cursor: MlsOwnershipCursor?) throws {
        guard page.version == 1, page.entries.count <= 100 else { throw ClientError.Unexpected("key_package_inventory_invalid") }
        var previous = cursor; var ids = Set<String>(); var refs = Set<Data>()
        for entry in page.entries {
            guard UUID(uuidString: entry.id) != nil, entry.key_package_ref.count == 32,
                  ids.insert(entry.id).inserted, refs.insert(entry.key_package_ref).inserted,
                  let date = Self.date(entry.created_at) else { throw ClientError.Unexpected("key_package_entry_invalid") }
            if let p = previous {
                guard let prior = Self.date(p.created_at), date > prior || date == prior && entry.id > p.id else { throw ClientError.Unexpected("key_package_cursor_invalid") }
            }
            previous = MlsOwnershipCursor(id: entry.id, created_at: entry.created_at)
        }
        guard page.next_cursor == nil || !page.entries.isEmpty && page.next_cursor == previous && page.next_cursor != cursor else { throw ClientError.Unexpected("key_package_cursor_invalid") }
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func refill(reason: String, remaining: Int) {
        do {
            try current()
            if state.upload != nil { upload(reason: reason, remaining: remaining); return }
            guard remaining >= 0 else { finish(); return }
            request(.keyPackagesCount(reason: reason)) { result in
                do {
                    let count = try result.get()
                    guard let size = E2eeKeyPackageRefillPolicy.batchSize(remaining: count.remaining, target: count.target, lowWatermark: count.lowWatermark,
                        requestedDelta: count.requestedDelta, refillGeneration: count.refillGeneration) else { throw ClientError.Unexpected("key_package_count_invalid") }
                    guard size > 0, remaining > 0 else { self.finish(); return }
                    var next = self.state; next.upload = .init(id: UUID().uuidString, status: "preparing", createdAt: self.now().timeIntervalSince1970)
                    next.upload?.generationVersion = 1; next.upload?.batchSize = size; next.upload?.nativeProviderId = try self.providerId()
                    try self.save(next)
                    self.upload(reason: reason, remaining: remaining)
                } catch { self.finish() }
            }
        } catch { finish() }
    }
    private func upload(reason: String, remaining: Int) {
        do {
            try current()
            guard var job = state.upload else { finish(); return }
            if job.status == "retained_legacy_preparing_unbound" ||
                job.status == "preparing" && (job.generationVersion == nil || job.batchSize == nil || job.nativeProviderId == nil) {
                do {
                    guard let batch = try recover(job.id) else {
                        job.status = "retained_legacy_preparing_unbound"; var next = state; next.upload = job; try save(next); finish(); return
                    }
                    try current()
                    job.bytes = batch.map { $0.0 }; job.refs = batch.map { $0.1 }
                    job.generationVersion = 1; job.batchSize = batch.count; job.nativeProviderId = try providerId(); job.status = "ready"
                    var next = state; next.upload = job; try save(next)
                } catch {
                    try current(); job.status = error is MlsKeyPackageBatchInvalid ? "retained_invalid_or_expired" : "retained_private_uncertain"
                    var next = state; next.upload = job; try save(next); finish(); return
                }
            }
            if job.status == "preparing" {
                guard job.generationVersion == 1, let count = job.batchSize, let nativeProviderId = job.nativeProviderId else {
                    job.status = "retained_legacy_preparing_unbound"; var next = state; next.upload = job; try save(next); finish(); return
                }
                guard try providerId() == nativeProviderId else {
                    job.status = "retained_provider_replaced"; var next = state; next.upload = job; try save(next); finish(); return
                }
                let batch: [(Data, Data)]
                do { batch = try generate(job.id, nativeProviderId, count) } catch {
                    try current(); job.status = error is MlsKeyPackageBatchInvalid ? "retained_invalid_or_expired" : "retained_private_uncertain"
                    var next = state; next.upload = job; try save(next); finish(); return
                }
                job.bytes = batch.map { $0.0 }; job.refs = batch.map { $0.1 }; job.status = "ready"
                // A public checkpoint failure leaves preparing (or committed
                // ready) on disk. Restart recovers the native exact journal.
                var next = state; next.upload = job; try save(next)
            }
            guard job.status == "ready", job.retryAt <= now().timeIntervalSince1970 else { finish(); return }
            if job.bytes.isEmpty || !job.bytes.allSatisfy({ validateKeyPackageBytes(data: $0) }) {
                job.status = "retained_invalid_or_expired"; var next = state; next.upload = job; try save(next); finish(); return
            }
            let referenceProvider = Provider()
            let derivedRefs = try job.bytes.map { try KeyPackage.fromBytes(data: $0).hashRef(provider: referenceProvider) }
            if derivedRefs != job.refs {
                job.status = "retained_invalid_or_expired"; var next = state; next.upload = job; try save(next); finish(); return
            }
            if !(try probe(job.refs)).allSatisfy({ $0 }) {
                job.status = "retained_private_uncertain"; var next = state; next.upload = job; try save(next); finish(); return
            }
            job.attempts = min(1_000_000, job.attempts + 1); job.retryAt = MlsKeyPackageWorkStore.retryAt(now: now().timeIntervalSince1970, attempts: job.attempts)
            var next = state; next.upload = job; try save(next)
            request(.uploadKeyPackages(keyPackages: job.bytes.map { Array($0) }, operationId: job.id)) { result in
                do {
                    let ack = try result.get()
                    guard ack.validationVersion == 1, UUID(uuidString: ack.batchId) == UUID(uuidString: job.id), (0...job.bytes.count).contains(ack.stored) else { throw ClientError.Unexpected("key_package_ack_invalid") }
                    var next = self.state; next.upload = nil; try self.save(next)
                    self.refill(reason: reason, remaining: remaining - 1)
                } catch {
                    if let rejection = error as? MlsKeyPackageUploadRejection, UUID(uuidString: rejection.batchId) == UUID(uuidString: job.id) {
                        var next = self.state; next.upload?.status = "retained_server_rejected"; try? self.save(next)
                    }
                    self.finish()
                } // Exact bytes remain for both typed rejection and unknown transport.
            }
        } catch { finish() }
    }
    private func finish() {
        guard !finished else { return }
        if now() < deadline {
            do { try current(); if state.leaseId == operationId { var next = state; next.leaseId = nil; next.leaseUntil = 0; try save(next) } } catch { }
        }
        finished = true
        let nextDue = min(state.retryAt > 0 ? state.retryAt : started.timeIntervalSince1970,
                          state.retries.map { $0.retryAt }.min() ?? .greatestFiniteMagnitude,
                          state.upload?.retryAt ?? .greatestFiniteMagnitude)
        completion(max(deadline.timeIntervalSince1970, nextDue, state.leaseUntil))
    }
}
