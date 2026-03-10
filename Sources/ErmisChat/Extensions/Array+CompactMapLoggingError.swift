//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisShared

extension Collection {
    @inlinable
    func compactMapLoggingError<ElementOfResult>(_ transform: (Element) throws -> ElementOfResult?) -> [ElementOfResult] {
        compactMap {
            do {
                return try transform($0)
            } catch {
                log.warning(error)
                return nil
            }
        }
    }
}
