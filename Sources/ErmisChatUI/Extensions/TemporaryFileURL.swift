//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

extension Data {
    public func copyToTemporaryLocalFileUrl(_ fileName: String) throws -> URL {
        let documentDirectory = NSTemporaryDirectory()
        let localPath = documentDirectory.appending(fileName)
        let tempURL = URL(fileURLWithPath: localPath)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try self.write(to: tempURL)
        return tempURL
    }
}

extension URL {
    public func copyToTemporaryLocalFileUrl() throws -> URL {
        let documentDirectory = NSTemporaryDirectory()
        let localPath = documentDirectory.appending(lastPathComponent)
        let tempURL = URL(fileURLWithPath: localPath)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.copyItem(at: self, to: tempURL)
        return tempURL
    }
}
