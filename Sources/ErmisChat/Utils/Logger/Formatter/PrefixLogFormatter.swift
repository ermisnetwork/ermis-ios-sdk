//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Formats the given log message with the given prefixes by log level.
/// Useful for emphasizing different leveled messages on console, when used as:
/// `prefixes: [.info: "ℹ️", .debug: "🛠", .error: "❌", .fault: "🚨"]`
public class PrefixLogFormatter: LogFormatter {
    private let prefixes: [LogLevel: String]

    public init(prefixes: [LogLevel: String]) {
        self.prefixes = prefixes
    }

    public func format(logDetails: LogDetails, message: String) -> String {
        prefixes[logDetails.level, default: ""] + " " + message
    }
}
