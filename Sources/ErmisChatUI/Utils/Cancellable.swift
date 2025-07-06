//
// Copyright 2025 Ermis Inc.
//

import Foundation

///// Cancellable provides a set of functions that enable cancelling a task
public protocol Cancellable: AnyObject {
    func cancel()
}
