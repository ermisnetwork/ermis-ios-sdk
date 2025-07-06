//
// Copyright 2025 Ermis Inc.
//

import CoreGraphics

extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        var result = self
        result.x += dx
        result.y += dy
        return result
    }
}
