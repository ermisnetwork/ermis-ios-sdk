//
// Copyright 2025 Ermis Inc.
//

import AVKit
import ErmisChat
import UIKit

/// A protocol the video loader must conform to.
public protocol VideoLoading: AnyObject {

    /// Get a preview for the video at given URL.
    /// - Parameters:
    ///   - url: A video URL.
    /// - Returns: The preivew image of this video.
    func previewForVideo(at url: URL) -> UIImage?

    /// Loads a preview for the video at given URL.
    /// - Parameters:
    ///   - url: A video URL.
    ///   - completion: A completion that is called when a preview is loaded. Must be invoked on main queue.
    func loadPreviewForVideo(at url: URL, completion: @escaping (Result<UIImage, Error>) -> Void)

    /// Loads video duration without synchronously resolving AVAsset properties on the main
    /// thread. The completion is always delivered on the main queue.
    func loadDurationForVideo(at url: URL, completion: @escaping (Result<TimeInterval, Error>) -> Void)

    /// Returns a video asset with the given URL.
    ///
    /// - Returns: The video asset.
    func videoAsset(at url: URL) -> AVURLAsset
}

public extension VideoLoading {
    func videoAsset(at url: URL) -> AVURLAsset {
        .init(url: url)
    }

    func loadDurationForVideo(
        at url: URL,
        completion: @escaping (Result<TimeInterval, Error>) -> Void
    ) {
        let asset = videoAsset(at: url)
        _Concurrency.Task {
            let result: Result<TimeInterval, Error>
            do {
                let duration = try await asset.load(.duration)
                result = .success(duration.seconds)
            } catch {
                result = .failure(error)
            }
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}

/// The default `VideoLoading` implementation.
open class ErmisVideoLoader: VideoLoading {
    private let cache: Cache<URL, UIImage>

    public init(cachedVideoPreviewsCountLimit: Int = 50) {
        cache = .init(countLimit: cachedVideoPreviewsCountLimit)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning(_:)),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func previewForVideo(at url: URL) -> UIImage? {
        return cache[url]
    }

    open func loadPreviewForVideo(at url: URL, completion: @escaping (Result<UIImage, Error>) -> Void) {
        if let cached = cache[url] {
            return call(completion, with: .success(cached))
        }

        let asset = videoAsset(at: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        let frameTime = CMTime(seconds: 0.1, preferredTimescale: 600)

        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.generateCGImagesAsynchronously(forTimes: [.init(time: frameTime)]) { [weak self] _, image, _, _, error in
            guard let self = self else { return }

            let result: Result<UIImage, Error>
            if let thumbnail = image {
                result = .success(.init(cgImage: thumbnail))
            } else if let error = error {
                result = .failure(error)
            } else {
                log.error("Both error and image are `nil`.")
                return
            }

            self.cache[url] = try? result.get()
            self.call(completion, with: result)
        }
    }

    open func videoAsset(at url: URL) -> AVURLAsset {
        .init(url: url)
    }

    private func call(_ completion: @escaping (Result<UIImage, Error>) -> Void, with result: Result<UIImage, Error>) {
        if Thread.current.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    @objc open func handleMemoryWarning(_ notification: NSNotification) {
        cache.removeAllObjects()
    }
}
