//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

extension ImageTask: Cancellable {}

/// The class which is responsible for loading images from URLs.
/// Internally uses `Nuke`'s shared object of `ImagePipeline` to load the image.
open class NukeImageLoader: ImageLoading, ImagePipelineDelegate {
    public init() {
        let dataCache = try! DataCache(name: "network.ermis.uhm.data-cache")
        dataCache.sizeLimit = 414_515_200 // 200 mb

        var configuration = ImagePipeline.shared.configuration
        configuration.dataCache = dataCache
        configuration.imageCache = ImageCache.shared
        configuration.isDecompressionEnabled = false
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.shared
        configuration.dataLoader = DataLoader(configuration: config)
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }

    open var avatarThumbnailSize: CGSize {
        Components.default.avatarThumbnailSize
    }

    open var imageCDN: ImageCDN {
        Components.default.imageCDN
    }
    
    var imagePipeline: NukeImagePipelineLoading {
        return ImagePipeline.shared
    }

    private lazy var operationQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "network.ermis.download-multiple-images"
        operationQueue.maxConcurrentOperationCount = 2
        return operationQueue
    }()

    @discardableResult
    open func loadImage(
        into imageView: UIImageView,
        from url: URL?,
        with options: ImageLoaderOptions,
        completion: ((Result<UIImage, Error>) -> Void)?
    ) -> Cancellable? {
        guard let url = url, !url.absoluteString.isEmpty else {
            imageView.currentImageLoadingTask?.cancel()
            let placeHolder = options.placeholder ?? PlaceholderImageGenerator.shared.getPlaceHolderImage(from: options.placeHolderString ?? " ")
            imageView.image = placeHolder
            completion?(.success(placeHolder))
            return nil
        }
        let urlRequest = imageCDN.urlRequest(forImageUrl: url, resize: options.resize)
        let cachingKey = imageCDN.cachingKey(forImageUrl: url)

        var processors: [ImageProcessing] = []
        if let resize = options.resize {
            let cgSize = CGSize(width: resize.width, height: resize.height)
            processors.append(ImageProcessors.Resize(size: cgSize))
        }

        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: processors,
            userInfo: [.imageIdKey: cachingKey]
        )

        let nukeOptions = ImageLoadingOptions(placeholder: options.placeholder)
        let loadingTask = ErmisChatUI.loadImage(
            with: request,
            options: nukeOptions,
            into: imageView
        ) { [weak imageView] result in
            switch result {
            case let .success(imageResponse):
                completion?(.success(imageResponse.image))
            case let .failure(error):
                imageView?.image = options.placeholder ?? PlaceholderImageGenerator.shared.getPlaceHolderImage(from: options.placeHolderString ?? " ")
                completion?(.failure(error))
            }
        }

        imageView.currentImageLoadingTask = loadingTask
        return loadingTask
    }

    @discardableResult
    open func downloadImage(
        with request: ImageDownloadRequest,
        completion: @escaping ((Result<UIImage, Error>) -> Void)
    ) -> Cancellable? {
        let url = request.url
        let options = request.options
        let urlRequest = imageCDN.urlRequest(forImageUrl: url, resize: options.resize)
        let cachingKey = imageCDN.cachingKey(forImageUrl: url)

        var processors: [ImageProcessing] = []
        if let resize = options.resize {
            let cgSize = CGSize(width: resize.width, height: resize.height)
            processors.append(ImageProcessors.Resize(size: cgSize))
        }

        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: processors,
            userInfo: [.imageIdKey: cachingKey]
        )

        return imagePipeline.loadImage(with: request, completion: completion)
    }

    open func downloadMultipleImages(
        with requests: [ImageDownloadRequest],
        completion: @escaping (([Result<UIImage, Error>]) -> Void)
    ) {
        let group = DispatchGroup()
        var results = [Result<UIImage, Error>](repeating: .failure(NSError.unknown), count: requests.count)
        
        for (index, request) in requests.enumerated() {
            let url = request.url
            let downloadOptions = request.options

            group.enter()

            let request = ImageDownloadRequest(url: url, options: downloadOptions)
            downloadImage(with: request) { result in
                results[index] = result

                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }
}


protocol NukeImagePipelineLoading {
    @discardableResult func loadImage(
        with request: ImageRequest,
        completion: @escaping (_ result: Result<UIImage, Error>) -> Void
    ) -> ImageTask
}

extension ImagePipeline: NukeImagePipelineLoading {
    func loadImage(with request: ImageRequest, completion: @escaping (Result<UIImage, Swift.Error>) -> Void) -> ImageTask {
        loadImage(with: request) { result in
            switch result {
            case let .success(imageResponse):
                completion(.success(imageResponse.image))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }
}

private extension NSError {
    static var unknown: NSError {
        NSError(domain: NSURLErrorDomain, code: URLError.Code.unknown.rawValue)
    }
}

extension UIImageView {
    static var nukeLoadingTaskKey: UInt8 = 0

    var currentImageLoadingTask: ImageTask? {
        get { objc_getAssociatedObject(self, &Self.nukeLoadingTaskKey) as? ImageTask }
        set { objc_setAssociatedObject(self, &Self.nukeLoadingTaskKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
