//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Array where Element == URLQueryItem {
    var prettyPrinted: String {
        var message = ""

        forEach { item in
            if let value = item.value,
               value.hasPrefix("{"),
               let data = value.data(using: .utf8) {
                message += "- \(item.name)=\(data.debugPrettyPrintedJSON ?? "")\n"
            } else if item.name != "api_key" && item.name != "user_id" && item.name != "client_id" {
                message += "- \(item.description)\n"
            }
        }

        if message.isEmpty {
            message = "<Empty>"
        }

        return message
    }
}
