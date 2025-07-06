//
// Copyright 2025 Ermis Inc.
//

import UIKit

public protocol RemoteImageDisplayable: AnyObject {
    var imageDownloadTask: Cancellable? { get set }
    var imageView: UIImageView { get }

    func loadImage(from url: URL?,
                   with options: ImageLoaderOptions,
                   completion: ((Result<UIImage, Error>) -> Void)?)
    func cancelImageLoading()
}

extension RemoteImageDisplayable where Self: ComponentsProvider {
    public func loadImage(from url: URL?,
                          with options: ImageLoaderOptions = .init(),
                   completion: ((Result<UIImage, Error>) -> Void)? = nil) {
        cancelImageLoading()
        imageDownloadTask = components.imageLoader.loadImage(into: imageView,
                                                             from: url, with: options,
                                                             completion: { [weak self, weak imageView] result in
            completion?(result)
            self?.cancelImageLoading()
        })
    }

    public func cancelImageLoading() {
        imageDownloadTask?.cancel()
        imageDownloadTask = nil
    }
}
