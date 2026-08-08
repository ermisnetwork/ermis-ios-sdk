//
// Copyright 2025 Ermis Inc.
//

import Foundation

enum MlsMutationExecutorError: Error {
    case operationCancelled
}

/// The only runtime executor allowed to mutate OpenMLS group state.
///
/// OpenMLS groups share one SQLite provider. Until provider-level concurrent mutation is proven
/// safe, the executor deliberately uses one worker globally. Per-scope dependencies additionally
/// preserve enqueue order when a high-priority realtime/send operation is queued behind an older
/// low-priority sync operation for the same MLS group.
final class MlsMutationExecutor {
    private final class MutationOperation: Operation, @unchecked Sendable {
        weak var owner: MlsMutationExecutor?
        let work: () -> Void

        init(owner: MlsMutationExecutor, work: @escaping () -> Void) {
            self.owner = owner
            self.work = work
        }

        override func main() {
            guard !isCancelled, let owner else { return }
            owner.withExecutionScope(work)
        }
    }

    private let queue: OperationQueue
    private let stateLock = NSLock()
    private var lastOperationByScope: [String: Operation] = [:]
    private var isStopping = false
    private let executionKey: String

    init(label: String = "io.ermis.e2e.mls-mutation") {
        executionKey = "\(label).\(UUID().uuidString)"
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = label
    }

    var isExecuting: Bool {
        Thread.current.threadDictionary[executionKey] as? Bool == true
    }

    @discardableResult
    func enqueue(
        scopeIds: Set<String>,
        priority: Operation.QueuePriority = .normal,
        work: @escaping () -> Void
    ) -> Operation {
        let operation = MutationOperation(owner: self, work: work)
        operation.queuePriority = priority

        stateLock.lock()
        if isStopping {
            operation.cancel()
        } else {
            for scopeId in scopeIds {
                if let previous = lastOperationByScope[scopeId], !previous.isFinished {
                    operation.addDependency(previous)
                }
                lastOperationByScope[scopeId] = operation
            }
        }
        queue.addOperation(operation)
        stateLock.unlock()
        return operation
    }

    func sync<T>(
        scopeIds: Set<String>,
        priority: Operation.QueuePriority = .normal,
        work: @escaping () throws -> T
    ) throws -> T {
        if isExecuting {
            return try work()
        }

        var result: Result<T, Error>?
        let operation = enqueue(scopeIds: scopeIds, priority: priority) {
            result = Result { try work() }
        }
        operation.waitUntilFinished()
        guard let result else {
            throw MlsMutationExecutorError.operationCancelled
        }
        return try result.get()
    }

    func assertIsExecuting(file: StaticString = #fileID, line: UInt = #line) {
        assert(
            isExecuting,
            "OpenMLS group mutation occurred outside MlsMutationExecutor",
            file: file,
            line: line
        )
    }

    func cancelAllAndWait() {
        assert(!isExecuting, "Cannot synchronously stop MlsMutationExecutor from its own worker")
        stateLock.lock()
        isStopping = true
        queue.cancelAllOperations()
        stateLock.unlock()
        queue.waitUntilAllOperationsAreFinished()
        stateLock.lock()
        lastOperationByScope.removeAll()
        isStopping = false
        stateLock.unlock()
    }

    private func withExecutionScope(_ work: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[executionKey]
        dictionary[executionKey] = true
        defer {
            if let previous {
                dictionary[executionKey] = previous
            } else {
                dictionary.removeObject(forKey: executionKey)
            }
        }
        work()
    }
}
