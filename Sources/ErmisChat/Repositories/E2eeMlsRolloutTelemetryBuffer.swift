import Foundation

final class E2eeMlsRolloutTelemetryBuffer {
    typealias Sender = (
        _ observations: [E2eeMlsRolloutMetricObservation],
        _ completion: @escaping () -> Void
    ) -> Void

    enum RecordResult: Equatable {
        case accepted
        case droppedQueueFull
    }

    private let lock = NSLock()
    private let sender: Sender
    private let maximumPending = 32
    private let maximumBatch = 16
    private var pending: [E2eeMlsRolloutMetricObservation] = []
    private var isSending = false

    init(sender: @escaping Sender) {
        self.sender = sender
    }

    @discardableResult
    func record(_ observation: E2eeMlsRolloutMetricObservation) -> RecordResult {
        lock.lock()
        guard pending.count < maximumPending else {
            lock.unlock()
            return .droppedQueueFull
        }
        pending.append(observation)
        let batch = takeBatchIfIdleLocked()
        lock.unlock()
        send(batch)
        return .accepted
    }

    var pendingCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    private func takeBatchIfIdleLocked() -> [E2eeMlsRolloutMetricObservation] {
        guard !isSending, !pending.isEmpty else { return [] }
        isSending = true
        let count = min(maximumBatch, pending.count)
        let batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        return batch
    }

    private func send(_ batch: [E2eeMlsRolloutMetricObservation]) {
        guard !batch.isEmpty else { return }
        sender(batch) { [weak self] in
            self?.didCompleteSend()
        }
    }

    private func didCompleteSend() {
        lock.lock()
        isSending = false
        let batch = takeBatchIfIdleLocked()
        lock.unlock()
        send(batch)
    }
}
