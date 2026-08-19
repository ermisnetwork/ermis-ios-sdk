import AVFoundation
import UIKit
import XCTest
@testable import ErmisChatUI

final class VideoAttachmentComposerPreviewTests: XCTestCase {
    @MainActor
    func testExistingThumbnailHidesSpinnerWithoutStartingAnotherPreviewLoad() {
        let previousLoader = Components.default.videoLoader
        let loader = ComposerVideoLoaderSpy()
        Components.default.videoLoader = loader
        defer { Components.default.videoLoader = previousLoader }

        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let container = UIView()
        let view = VideoAttachmentComposerPreview()
        container.addSubview(view)
        view.content = .init(
            url: URL(fileURLWithPath: "/tmp/video.mov"),
            thumbnailImage: thumbnail,
            duration: 1
        )

        XCTAssertTrue(view.loadingIndicator.isHidden)
        XCTAssertNotNil(view.previewImageView.image)
        XCTAssertEqual(loader.previewLoadCount, 0)
    }
}

private final class ComposerVideoLoaderSpy: VideoLoading {
    private(set) var previewLoadCount = 0

    func previewForVideo(at url: URL) -> UIImage? { nil }

    func loadPreviewForVideo(
        at url: URL,
        completion: @escaping (Result<UIImage, Error>) -> Void
    ) {
        previewLoadCount += 1
    }

    func videoAsset(at url: URL) -> AVURLAsset { AVURLAsset(url: url) }
}
