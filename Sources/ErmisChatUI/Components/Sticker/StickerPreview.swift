//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit
import Lottie
import zlib

/// View for displaying sticker content.
open class StickerPreview: _View, UIProvider, RemoteImageDisplayable {
    public private(set) lazy var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.layer.masksToBounds = true
        imageView.clipsToBounds = true
        return imageView
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "imageView")
    }()

    /// A view for displaying .tgs stickers.
    public private(set) var animationView: LottieAnimationView?

    public var showImageTask: _Concurrency.Task<Void, Never>?

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    open override func setUp() {

    }

    open override func setUpUI() {
        embed(imageView)
    }

    open override func setUpTheme() {
        self.backgroundColor = .clear
    }

    open override func contentDidChanged() {
        cancelImageTask()
        animationView?.removeFromSuperview()
        animationView = nil

        guard let content = content, !content.isEmpty else {
            return
        }

        let isTGSFile = content.url.pathExtension == "tgs"
        imageView.isHidden = isTGSFile
        imageView.currentImageLoadingTask?.cancel()

        // If the sticker has data, display it directly.
        // Otherwise, load and display it from the URL.
        if isTGSFile, let data = content.sticker?.data {
            showImageTask = _Concurrency.Task { [weak self] in
                let animation = try? await decodeAnimation(data: data)
                guard !_Concurrency.Task.isCancelled, let animation else {
                    return
                }
                await MainActor.run { [weak self] in
                    guard !_Concurrency.Task.isCancelled else {
                        return
                    }
                    self?.showStickerAnimation(animation)
                    self?.showImageTask = nil
                }
            }
        } else if !isTGSFile, let image = content.sticker?.image {
            self.imageView.image = image
        } else {
            self.showContentFromURL(content.url)
        }
    }

    private func cancelImageTask() {
        showImageTask?.cancel()
        showImageTask = nil
    }

    public func prepareForReuse() {
        cancelImageTask()
        imageView.image = nil
        animationView?.stop()
        animationView?.animation = nil
        animationView?.removeFromSuperview()
    }

    /// Creates a `LottieAnimation` from the given data.
    /// - Parameter data: The extracted data from a `.tgs` file.
    /// - Returns: A `LottieAnimation` instance.
    private func decodeAnimation(data: Data) async throws -> LottieAnimation {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
                    let animation = try LottieAnimation(dictionary: json)
                    continuation.resume(returning: animation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func showContentFromURL(_ url: URL) {
        let isTGSFile = url.pathExtension == "tgs"
        if isTGSFile {
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self,
                      let data = data,
                      let json = try? self.jsonFromCompressedData(data),
                      let animation = try? LottieAnimation(dictionary: json) else {
                    return
                }

                DispatchQueue.main.async(execute: {
                    self.showStickerAnimation(animation)
                })
            }.resume()

        } else {
            loadImage(from: url, with: ImageLoaderOptions(
                resize: .init(CGSize(width: 150, height: 150)),
                placeHolderString: nil
            ))
        }
    }

    private func showStickerAnimation(_ animation: LottieAnimation) {
        if animationView == nil {
            let config = LottieConfiguration(renderingEngine: .coreAnimation)
            let animationView = LottieAnimationView(animation: nil, configuration: config)
                .withoutAutoresizingMaskConstraints
            animationView.loopMode = .loop
            animationView.contentMode = .scaleAspectFit
            animationView.isUserInteractionEnabled = false
            embed(animationView)
            self.animationView = animationView
        }

        self.animationView?.animation = animation
        self.animationView?.play()
    }

    /// Extracts the animation JSON from `.tgs` data.
    /// - Parameter data: The `.tgs` file data.
    /// - Returns: The animation JSON.
    private func jsonFromCompressedData(_ data: Data) -> [String: Any]? {
        guard let decompressed = gunzip(data: data) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: decompressed, options: [])) as? [String: Any]
    }

    /// Uncompressed data of a `.tgs` file.
    /// - Parameter data: The `.tgs` file data.
    /// - Returns: The uncompressed data.
    private func gunzip(data: Data) -> Data? {
        guard data.count > 0 else { return nil }
        var stream = z_stream()
        var status: Int32
        status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var decompressed = Data()
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let srcPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcPtr)
            stream.avail_in = uint(data.count)
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let have = bufferSize - Int(stream.avail_out)
                if have > 0 {
                    decompressed.append(buffer, count: have)
                }
            } while status == Z_OK
            return status == Z_STREAM_END ? decompressed : nil
        }
    }
}
// MARK: - Content
extension StickerPreview {
    public struct Content {
        public var url: URL
        public var sticker: Sticker?

        public var isEmpty: Bool {
            return url == nil && sticker?.data == nil
        }
    }
}
