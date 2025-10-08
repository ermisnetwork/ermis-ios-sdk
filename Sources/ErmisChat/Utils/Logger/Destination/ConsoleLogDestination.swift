//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Basic destination for outputting messages to console.
public class ConsoleLogDestination: BaseLogDestination {
    private let fileName = "uhm.txt"
    private var logFileURL: URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(fileName)
    }

    override open func write(message: String) {
        print(message)
//        appendToLogFile(message)
    }

    func appendToLogFile(_ message: String) {
        var content = message
        content.append(contentsOf: "\n")
        let data = content.data(using: .utf8)!
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                try? handle.seekToEnd()
                try? handle.write(data)
                try? handle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
}
