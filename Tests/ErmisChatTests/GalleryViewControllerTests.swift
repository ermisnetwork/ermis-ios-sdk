//
// Copyright 2026 Ermis Inc.
//

@testable import ErmisChatUI
import UIKit
import XCTest

@MainActor
final class GalleryViewControllerTests: XCTestCase {
    func testPanWithoutZoomTransitionDoesNotCrash() {
        let gallery = GalleryViewController()

        // Channel Info can use the system modal transition. Its gallery must keep
        // the close button usable instead of force-unwrapping a missing zoom controller.
        gallery.handlePan(with: UIPanGestureRecognizer())

        XCTAssertNil(gallery.transitionController)
    }
}
