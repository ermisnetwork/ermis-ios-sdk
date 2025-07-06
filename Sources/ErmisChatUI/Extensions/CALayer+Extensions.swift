//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension CALayer {
    func addShadow(color: UIColor, radius: CGFloat = 8) {
        masksToBounds = false
        shadowColor = color.cgColor
        shadowOffset = .zero
        shadowRadius = radius
        shadowOpacity = 1.0
    }
}
