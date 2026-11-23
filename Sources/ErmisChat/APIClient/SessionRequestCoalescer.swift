import Foundation

/// Shares an in-flight metadata result across App/ChannelList callers; later refreshes remain explicit reads.
final class SessionRequestCoalescer<Value> {
    private final class Entry {
        let assertOwner: () throws -> Void
        var callbacks: [(Result<Value, Error>) -> Void]
        init(owner: @escaping () throws -> Void, callback: @escaping (Result<Value, Error>) -> Void) { assertOwner = owner; callbacks = [callback] }
    }
    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]
    func request(key: Data, owner: @escaping () throws -> Void,
                 completion: @escaping (Result<Value, Error>) -> Void,
                 start: (@escaping (Result<Value, Error>) -> Void) -> Void) {
        lock.lock()
        if let held = entries[key], (try? held.assertOwner()) != nil {
            held.callbacks.append(completion); lock.unlock(); return
        }
        let entry = Entry(owner: owner, callback: completion); entries[key] = entry; lock.unlock()
        start { result in
            self.lock.lock(); if self.entries[key] === entry { self.entries.removeValue(forKey: key) }
            let callbacks = entry.callbacks; entry.callbacks.removeAll(); self.lock.unlock()
            let delivered: Result<Value, Error>
            do { try entry.assertOwner(); delivered = result } catch { delivered = .failure(error) }
            callbacks.forEach { $0(delivered) }
        }
    }
}
