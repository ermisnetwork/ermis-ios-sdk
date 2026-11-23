//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Persists a watch response without monopolizing the shared database writer.
/// A channel remains atomic; the next one is submitted only after its save ACK,
/// from outside the database context so queued live writes can run in between.
enum WatchedChannelPageWriter {
    static func save<Element>(
        _ elements: [Element],
        persist: @escaping (Element, @escaping (Error?) -> Void) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        Writer(elements: elements, persist: persist, completion: completion).start()
    }

    private final class Writer<Element> {
        private let elements: [Element]
        private let persist: (Element, @escaping (Error?) -> Void) -> Void
        private let completion: (Error?) -> Void
        private let queue = DispatchQueue(label: "network.ermis.watched-channel-page-writer")
        private var index = 0
        private var finished = false

        init(
            elements: [Element],
            persist: @escaping (Element, @escaping (Error?) -> Void) -> Void,
            completion: @escaping (Error?) -> Void
        ) {
            self.elements = elements
            self.persist = persist
            self.completion = completion
        }

        func start() {
            queue.async { self.persistNext() }
        }

        private func persistNext() {
            guard index < elements.count else {
                finished = true
                completion(nil)
                return
            }
            let savedIndex = index
            persist(elements[savedIndex]) { error in
                self.queue.async {
                    guard !self.finished, self.index == savedIndex else { return }
                    if let error = error {
                        self.finished = true
                        self.completion(error)
                        return
                    }
                    self.index += 1
                    self.persistNext()
                }
            }
        }
    }
}
