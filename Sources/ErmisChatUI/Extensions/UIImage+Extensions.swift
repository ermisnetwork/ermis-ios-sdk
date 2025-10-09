//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

public
extension UIImage {
    convenience init?(named name: String, in bundle: Bundle) {
        self.init(named: name, in: bundle, compatibleWith: nil)
    }
}

extension UIImage {
    func tinted(with fillColor: UIColor) -> UIImage? {
        let image = withRenderingMode(.alwaysTemplate)
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        fillColor.set()
        image.draw(in: CGRect(origin: .zero, size: size))

        guard let imageColored = UIGraphicsGetImageFromCurrentImageContext() else {
            return nil
        }

        UIGraphicsEndImageContext()
        return imageColored
    }
}

extension UIImage {
    public func temporaryLocalFileUrl(fileName: String? = nil) throws -> URL {
        guard let imageData = jpegData(compressionQuality: 1.0) else {
            throw ClientError.Unknown("Failed to convert image to data")
        }
        let imageName = fileName == nil ? "\(UUID().uuidString).jpeg" : "\(fileName!).jpeg"
        let documentDirectory = NSTemporaryDirectory()
        let localPath = documentDirectory.appending(imageName)
        let photoURL = URL(fileURLWithPath: localPath)
        try imageData.write(to: photoURL)
        return photoURL
    }
}
