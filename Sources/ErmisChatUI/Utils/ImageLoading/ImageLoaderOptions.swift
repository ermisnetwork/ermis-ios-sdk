//
// Copyright 2025 Ermis Inc.
//

import UIKit

/// The options for loading an image into a view.
public struct ImageLoaderOptions {
    // Ideally, the name would be `ImageLoadingOptions`, but this would conflict with Nuke.

    /// The resize information when loading an image. `Nil` if you want the full resolution of the image.
    public var resize: ImageResize?

    /// The placeholder to be used while the image is finishing loading. Used if placeHolderString nil.
    public var placeholder: UIImage?
    /// The placeholder name for generated place holder, if this nil, the place holder will be used.
    public var placeHolderString: String?

    public init(resize: ImageResize? = nil,
                placeHolderString: String? = nil,
                placeholder: UIImage? = nil) {
        self.placeholder = placeholder
        self.placeHolderString = placeHolderString?.firstUppercased
        self.resize = resize
    }
}
