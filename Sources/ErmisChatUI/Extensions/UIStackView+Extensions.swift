//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension UIStackView {
    func removeAllArrangedSubviews() {
        let subviews = arrangedSubviews
        subviews.forEach { self.removeArrangedSubview($0) }
    }
}
