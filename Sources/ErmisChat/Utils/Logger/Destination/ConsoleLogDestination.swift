//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Basic destination for outputting messages to console.
public class ConsoleLogDestination: BaseLogDestination {
    override open func write(message: String) {
        print(message)
    }
}
