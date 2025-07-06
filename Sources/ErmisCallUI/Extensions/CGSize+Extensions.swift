//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension CGSize {
    var min: CGFloat {
        return CGFloat.minimum(width, height)
    }

    var max: CGFloat {
        return CGFloat.maximum(width, height)
    }
}
