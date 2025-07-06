//
// Copyright 2025 Ermis Inc.
//

import UIKit

open class PlaceholderImageGenerator {
    static let shared = PlaceholderImageGenerator()

    open func getPlaceHolderImage(from placeHolderString: String) -> UIImage {
        let nameCharacter = placeHolderString.first?.uppercased() ?? " "
        var colorCharacter: String?
        // Is wallet address
        if placeHolderString.hasPrefix("0x") {
            colorCharacter = placeHolderString.last?.uppercased()
        } else {
            colorCharacter = placeHolderString.first?.uppercased()
        }

        if colorCharacter == nil {
            colorCharacter = " "
        }

        let cachedKey = nameCharacter + colorCharacter!

        if let cachedImage = ImageCache.shared[ImageCacheKey(key: cachedKey)] {
            return cachedImage.image
        } else {

            let image = generatePlaceHolderImage(from: nameCharacter,
                                                 colors: getBackgroundColors(from: placeHolderString))
            ImageCache.shared[ImageCacheKey(key: cachedKey)] = ImageContainer(image: image)
            return image
        }
    }

    open func generatePlaceHolderImage(from string: String,
                                       size: CGSize = CGSize(width: 40, height: 40),
                                       colors: [UIColor]) -> UIImage {
        let render = UIGraphicsImageRenderer(size: size)
        return render.image { context in
            let cgContext = context.cgContext
            let rect = CGRect(origin: .zero, size: size)
            //
//            cgContext.addEllipse(in: rect)
//            cgContext.clip()
            var colors = colors.isEmpty ? [BaseColor.primary] : colors
            // Add gradient background
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: colorSpace,
                                      colors: colors.map(\.cgColor) as CFArray,
                                      locations: [0, 1])!

            cgContext.drawLinearGradient(gradient,
                                         start: CGPoint(x: 0, y: 0),
                                         end: CGPoint(x: 0, y: size.height),
                                         options: [])
            // Add text
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.boldSystemFont(ofSize: 18)
            ]
            let textSize = string.size(withAttributes: attributes)
            let textOrigin = CGPoint(x: (size.width - textSize.width) / 2,
                                     y: (size.height - textSize.height) / 2)
            string.draw(at: textOrigin, withAttributes: attributes)
        }
    }

    open func getBackgroundColors(from name: String) -> [UIColor] {

        var firstCharacter: Character?
        // Is wallet address
        if name.hasPrefix("0x") {
            firstCharacter = name.last
        } else {
            firstCharacter = name.first
        }

        guard let colorCharacter = firstCharacter else {
            return []
        }

        switch String(colorCharacter).uppercased() {
        case "A":
            return ["#FF5733", "#C70039"].map { UIColor(hex: $0)}
        case "B":
            return ["#85C1E9", "#21618C"].map { UIColor(hex: $0)}
        case "C":
            return ["#DAF7A6", "#FFC300"].map { UIColor(hex: $0)}
        case "D":
            return ["#FFC0CB", "#FF1493"].map { UIColor(hex: $0)}
        case "E":
            return ["#8E44AD", "#2980B9"].map { UIColor(hex: $0)}
        case "F":
            return ["#F39C12", "#D35400"].map { UIColor(hex: $0)}
        case "G":
            return ["#AED6F1", "#2E86C1"].map { UIColor(hex: $0)}
        case "H":
            return ["#58D68D", "#28B463"].map { UIColor(hex: $0)}
        case "I":
            return ["#F4D03F", "#F39C12"].map { UIColor(hex: $0)}
        case "J":
            return ["#EB984E", "#CB4335"].map { UIColor(hex: $0)}
        case "K":
            return ["#A569BD", "#8E44AD"].map { UIColor(hex: $0)}
        case "L":
            return ["#F5B041", "#DC7633"].map { UIColor(hex: $0)}
        case "M":
            return ["#76D7C4", "#48C9B0"].map { UIColor(hex: $0)}
        case "N":
            return ["#85929E", "#34495E"].map { UIColor(hex: $0)}
        case "O":
            return ["#FF5733", "#900C3F"].map { UIColor(hex: $0)}
        case "P":
            return ["#5DADE2", "#2E86C1"].map { UIColor(hex: $0)}
        case "Q":
            return ["#ABEBC6", "#239B56"].map { UIColor(hex: $0)}
        case "R":
            return ["#FAD7A0", "#E59866"].map { UIColor(hex: $0)}
        case "S":
            return ["#D7DBDD", "#566573"].map { UIColor(hex: $0)}
        case "T":
            return ["#B2BABB", "#626567"].map { UIColor(hex: $0)}
        case "U":
            return ["#D2B4DE", "#8E44AD"].map { UIColor(hex: $0)}
        case "V":
            return ["#C39BD3", "#7D3C98"].map { UIColor(hex: $0)}
        case "W":
            return ["#BB8FCE", "#8E44AD"].map { UIColor(hex: $0)}
        case "X":
            return ["#F7DC6F", "#F1C40F"].map { UIColor(hex: $0)}
        case "Y":
            return ["#52BE80", "#27AE60"].map { UIColor(hex: $0)}
        case "Z":
            return ["#1ABC9C", "#16A085"].map { UIColor(hex: $0)}
        case "0":
            return ["#00FF00", "#006600"].map { UIColor(hex: $0)}
        case "1":
            return ["#FFFF00", "#FFD700"].map { UIColor(hex: $0)}
        case "2":
            return ["#FF0000", "#8B0000"].map { UIColor(hex: $0)}
        case "3":
            return ["#E6E6FA", "#D8BFD8"].map { UIColor(hex: $0)}
        case "4":
            return ["#0000FF", "#00008B"].map { UIColor(hex: $0)}
        case "5":
            return ["#800080", "#4B0082"].map { UIColor(hex: $0)}
        case "6":
            return ["#BADA55", "#8CBF3F"].map { UIColor(hex: $0)}
        case "7":
            return ["#8B4513", "#A0522D"].map { UIColor(hex: $0)}
        case "8":
            return ["#1E90FF", "#4169E1"].map { UIColor(hex: $0)}
        case "9":
            return ["#996633", "#663300"].map { UIColor(hex: $0)}
        default:
            return ["#B694F9", "#6C61DF"].map { UIColor(hex: $0)}
        }
    }
}
