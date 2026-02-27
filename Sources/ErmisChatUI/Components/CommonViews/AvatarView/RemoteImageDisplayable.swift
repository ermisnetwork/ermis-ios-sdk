//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisSharedUI

public protocol RemoteImageDisplayable: AnyObject {
    var imageView: UIImageView { get }

    func loadImage(from url: URL?,
                   with options: ImageLoaderOptions,
                   completion: ((Result<UIImage, Error>) -> Void)?)
}

extension RemoteImageDisplayable where Self: SharedComponentsProvider {
    public func loadImage(from url: URL?,
                          with options: ImageLoaderOptions = .init(resize: .init(UIScreen.main.bounds.size, mode: .clip)),
                   completion: ((Result<UIImage, Error>) -> Void)? = nil) {
        sharedComponents.imageLoader.loadImage(into: imageView,
                                                             from: url, with: options,
                                                             completion: { [weak self, weak imageView] result in
            completion?(result)
        })
    }
}
