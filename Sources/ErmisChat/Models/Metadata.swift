//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct Metadata: Codable {
    public let address: String?

    public init(localAddress: String?) {
        self.address = localAddress
    }
}
