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
        return setWeight(700)
    }

    public
    var semiBold: UIFont {
        return setWeight(600)
    }

    public
    var medium: UIFont {
        return setWeight(500)
    }

    public
    var italic: UIFont {
        withTraits(traits: .traitItalic)
    }

    func setWeight(_ weight: CGFloat) -> UIFont {
        func fourCharCode(_ string: String) -> UInt32 {
            var result: UInt32 = 0
            for char in string.utf8 {
                result = (result << 8) + UInt32(char)
            }
            return result
        }
        let variation: [NSNumber: Any] = [
            NSNumber(value: fourCharCode("wght")): weight
        ]
        let descriptor = fontDescriptor.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: variation
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
