//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension UILabel {
    var withAdjustingFontForContentSizeCategory: Self {
        adjustsFontForContentSizeCategory = true
        return self
    }

    var withBidirectionalLanguagesSupport: Self {
        textAlignment = .natural
        return self
    }

    func withNumberOfLines(_ numberOfLines: Int) -> Self {
        self.numberOfLines = numberOfLines
        return self
    }

    var multiline: Self {
        numberOfLines = 0
        return self
    }

    var centerTextAlignment: Self {
        textAlignment = .center
        return self
    }

    var calculateHeight: CGFloat {
        systemLayoutSizeFitting(CGSize(width: self.bounds.width,
                                       height: UIView.layoutFittingCompressedSize.height),
                                withHorizontalFittingPriority: .required,
                                verticalFittingPriority: .fittingSizeLevel).height
    }
}
