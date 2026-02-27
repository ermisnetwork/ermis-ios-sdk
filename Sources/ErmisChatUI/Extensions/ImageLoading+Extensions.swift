//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisSharedUI
import ErmisChat

extension ImageLoading {
    /// Load an image into an imageView from a given `ImageAttachmentPayload`.
    /// - Parameters:
    ///   - imageView: The image view where the image will be loaded.
    ///   - attachmentPayload: The image attachment payload.
    ///   - maxResolutionInPixels: The maximum number of pixels the loaded image should have.
    ///   - completion: The completion when the loading is finished.
    /// - Returns: A cancellable task.
    @discardableResult
    func loadImage(
        into imageView: UIImageView,
        from attachmentPayload: ImageAttachmentPayload?,
        maxResolutionInPixels: Double
    ) -> Cancellable? {
        loadImage(
            into: imageView,
            from: attachmentPayload,
            maxResolutionInPixels: maxResolutionInPixels,
            completion: nil
        )
    }

    @discardableResult
    func loadImage(
        into imageView: UIImageView,
        from attachmentPayload: ImageAttachmentPayload?,
        maxResolutionInPixels: Double,
        completion: ((_ result: Result<UIImage, Error>) -> Void)?
    ) -> Cancellable? {
        guard let originalWidth = attachmentPayload?.originalWidth,
              let originalHeight = attachmentPayload?.originalHeight else {
            return loadImage(
                into: imageView,
                from: attachmentPayload?.imageURL,
                with: ImageLoaderOptions(),
                completion: completion
            )
        }

        let imageSizeCalculator = ImageSizeCalculator()
        let newSize = imageSizeCalculator.calculateSize(
            originalWidthInPixels: originalWidth,
            originalHeightInPixels: originalHeight,
            maxResolutionTotalPixels: maxResolutionInPixels
        )

        return loadImage(
            into: imageView,
            from: attachmentPayload?.imageURL,
            with: ImageLoaderOptions(resize: .init(newSize)),
            completion: completion
        )
    }
}

