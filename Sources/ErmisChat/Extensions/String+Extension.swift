//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
extension String? {
    var isEmptyOrNil: Bool {
        switch self {
        case .some(let value):
            return value.isEmpty
        case .none:
            return true
        }
    }
}

extension String {
    /// Creates and returns a new unique id every time the variable is accessed.
    static var newUniqueId: String { UUID().uuidString.lowercased() }
}

public extension String {
    /// Generate channel Id
    static var randomId: String {
        var string = UUID().uuidString
        string.removeAll(where: { $0 == "-"})
        return string
    }
}
