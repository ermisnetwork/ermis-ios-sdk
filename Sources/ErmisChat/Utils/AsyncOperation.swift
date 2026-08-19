//
// Copyright 2025 Ermis Inc.
//

import Foundation

class AsyncOperation: BaseOperation {
    enum Output {
        case retry
        case `continue`
    }

    private let maxRetries: Int
    private(set) var executionBlock: (AsyncOperation, @escaping (_ output: Output) -> Void) -> Void
    private var executedRetries = 0
    private let retryQueue = DispatchQueue(label: "network.ermis.async-operation.retry")

    var canRetry: Bool {
        executedRetries < maxRetries && !isCancelled && !isFinished
    }

    init(maxRetries: Int = 0, executionBlock: @escaping (AsyncOperation, @escaping (_ output: Output) -> Void) -> Void) {
        self.maxRetries = maxRetries
        self.executionBlock = executionBlock
        super.init()
    }

    override func start() {
        if isCancelled {
            isFinished = true
            return
        }

        isExecuting = true
        execute()
    }

    private func execute() {
        executionBlock(self) { [weak self] output in
            self?.retryQueue.async { [weak self] in
                self?.handleResult(output)
            }
        }
    }

    private func handleResult(_ output: Output) {
        let shouldRetry = output == .retry && canRetry
        guard shouldRetry else {
            isExecuting = false
            isFinished = true
            return
        }

        executedRetries += 1
        execute()
    }
}

class BaseOperation: Operation {
    var queueLabel: String {
        return "network.ermis.base-operation"
    }

    private var _finished = false
    private var _executing = false
    private lazy var stateQueue = DispatchQueue(label: queueLabel, attributes: .concurrent)

    override var isExecuting: Bool {
        get {
            stateQueue.sync {
                _executing
            }
        }
        set {
            willChangeValue(for: \.isExecuting)
            stateQueue.async(flags: .barrier) {
                self._executing = newValue
            }
            didChangeValue(for: \.isExecuting)
        }
    }

    override var isFinished: Bool {
        get {
            stateQueue.sync {
                _finished
            }
        }
        set {
            willChangeValue(for: \.isFinished)
            stateQueue.async(flags: .barrier) {
                self._finished = newValue
            }
            didChangeValue(for: \.isFinished)
        }
    }
}

class SSEAsyncOperation: BaseOperation {
    enum Output {
        case retry
        case `continue`
    }

    private let maxRetries: Int
    private(set) var executionBlock: (SSEAsyncOperation, @escaping (_ output: Output) -> Void) -> Void
    private var executedRetries = 0
    private let retryQueue = DispatchQueue(label: "network.ermis.sse-async-operation.retry")

    var canRetry: Bool {
        executedRetries < maxRetries && !isCancelled && !isFinished
    }

    init(maxRetries: Int = 0, executionBlock: @escaping (SSEAsyncOperation, @escaping (_ output: Output) -> Void) -> Void) {
        self.maxRetries = maxRetries
        self.executionBlock = executionBlock
        super.init()
    }

    override func start() {
        if isCancelled {
            isFinished = true
            return
        }

        isExecuting = true
        execute()
    }

    private func execute() {
        executionBlock(self) { [weak self] output in
            self?.retryQueue.async { [weak self] in
                self?.handleResult(output)
            }
        }
    }

    private func handleResult(_ output: Output) {
        let shouldRetry = output == .retry && canRetry
        guard shouldRetry else {
            isExecuting = false
            isFinished = true
            return
        }

        executedRetries += 1
        execute()
    }
}

class BaseSSEOperation: Operation {
    private var _finished = false
    private var _executing = false
    private let stateQueue = DispatchQueue(label: "network.ermis.base-sse-operation", attributes: .concurrent)

    override var isExecuting: Bool {
        get {
            stateQueue.sync {
                _executing
            }
        }
        set {
            willChangeValue(for: \.isExecuting)
            stateQueue.async(flags: .barrier) {
                self._executing = newValue
            }
            didChangeValue(for: \.isExecuting)
        }
    }

    override var isFinished: Bool {
        get {
            stateQueue.sync {
                _finished
            }
        }
        set {
            willChangeValue(for: \.isFinished)
            stateQueue.async(flags: .barrier) {
                self._finished = newValue
            }
            didChangeValue(for: \.isFinished)
        }
    }
}
