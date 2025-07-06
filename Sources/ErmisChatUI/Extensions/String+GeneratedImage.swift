//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

extension String {
    func image(with attributes: [NSAttributedString.Key: Any]? = nil,
               size: CGSize? = nil) -> UIImage {
        let textSize = (self as NSString).size(withAttributes: attributes)
        let size = size ?? textSize
        return UIGraphicsImageRenderer(size: size).image(actions: { context in
            let textRect = textSize.centeredInRectWithSize(size)
            (self as NSString).draw(in: textRect, withAttributes: attributes)
            
        })
    }
}
