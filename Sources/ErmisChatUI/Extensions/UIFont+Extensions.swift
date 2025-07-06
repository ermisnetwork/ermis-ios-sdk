//
// Copyright 2025 Ermis Inc.
//

import UIKit

extension UIFont {
    func withTraits(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return UIFont(descriptor: descriptor!, size: pointSize)
    }

    public
    var bold: UIFont {
        withTraits(traits: .traitBold)
    }

    public
    var semiBold: UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName.traits: [
                UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold
            ]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    public
    var italic: UIFont {
        withTraits(traits: .traitItalic)
    }
}
