//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension UIScrollView {
    /// Whether the user is scrolling or not. (Example: Will return false if the scroll view was scrolled programmatically)
    var isTrackingOrDecelerating: Bool {
        isTracking || isDecelerating
    }
}
