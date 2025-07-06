//
// Copyright 2025 Ermis Inc.
//

import UIKit

public protocol ImageProcessor {
    /// Crop the image to a given size. The image is center-cropped
    /// - Parameters:
    ///   - image: The image to crop
    ///   - size: The size to which the image needs to be cropped
    /// - Returns: The cropped image
    func crop(image: UIImage, to size: CGSize) -> UIImage?

    /// Scale an image to a given size maintaing the aspect ratio.
    /// - Parameters:
    ///   - image: The image to scale
    ///   - size: The size to which the image needs to be scaled
    /// - Returns: The scaled image
    func scale(image: UIImage, to size: CGSize) -> UIImage

    func border(image: UIImage, width: CGFloat, cornerRadius: CGFloat, color: UIColor) -> UIImage?
}

/// This class provides resizing operations for `UIImage`. It internally uses `Nuke` porcessors to implement operations on images.
open class NukeImageProcessor: ImageProcessor {
    open func crop(image: UIImage, to size: CGSize) -> UIImage? {
        let imageProccessor = ImageProcessors.Resize(size: size, crop: true)
        return imageProccessor.process(image)
    }

    open func scale(image: UIImage, to size: CGSize) -> UIImage {
        // Determine the scale factor that preserves aspect ratio
        let widthRatio = size.width / image.size.width
        let heightRatio = size.height / image.size.height

        let scaleFactor = min(widthRatio, heightRatio)

        // Compute the new image size that preserves aspect ratio
        let scaledImageSize = CGSize(
            width: image.size.width * scaleFactor,
            height: image.size.height * scaleFactor
        )

        // Draw and return the resized UIImage
        let renderer = UIGraphicsImageRenderer(size: scaledImageSize)

        let scaledImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: scaledImageSize))
        }

        return scaledImage
    }

    open func border(image: UIImage, width: CGFloat, cornerRadius: CGFloat, color: UIColor) -> UIImage? {
        let scale = image.scale
        let imageSize = image.size
        let newSize = CGSize(width: imageSize.width + 2 * width,
                             height: imageSize.height + 2 * width)

        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            return nil
        }

        // Border path
        let borderRect = CGRect(origin: .zero, size: newSize)
        let borderPath = UIBezierPath(roundedRect: borderRect, cornerRadius: cornerRadius + width)
        color.setFill()
        borderPath.fill()

        // Image path
        let imageRect = CGRect(x: width, y: width, width: imageSize.width, height: imageSize.height)
        let imagePath = UIBezierPath(roundedRect: imageRect, cornerRadius: cornerRadius)
        imagePath.addClip()
        image.draw(in: imageRect)

        let roundedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return roundedImage
    }
}

/// Extension of `Nuke`'s `ImageProcessors`
extension ImageProcessors {
    /// Scales an image to a specified size.
    /// The getting of the size is offloaded via closure after the image is loaded.
    /// The View has time to layout and provide non-zero size.
    public struct LateResize: ImageProcessing {
        private var size: CGSize {
            var size: CGSize = .zero
            DispatchQueue.main.sync { size = sizeProvider() }
            return size
        }

        private let id: String
        private let sizeProvider: () -> CGSize

        /// Initializes the processor with size providing closure.
        /// - Parameters:
        ///   - id: Image identifier.
        ///   - sizeProvider: Closure to obtain size after the image is loaded.
        public init(id: String, sizeProvider: @escaping () -> CGSize) {
            self.id = id
            self.sizeProvider = sizeProvider
        }

        public func process(_ image: PlatformImage) -> PlatformImage? {
            let size = self.size
            guard size != .zero else { return image }

            return ImageProcessors.Resize(
                size: size,
                unit: .points,
                contentMode: .aspectFill,
                upscale: false
            )
            .process(image)
        }

        public var identifier: String {
            "com.github.kean/nuke/lateResize?id=\(id)"
        }
    }
}
