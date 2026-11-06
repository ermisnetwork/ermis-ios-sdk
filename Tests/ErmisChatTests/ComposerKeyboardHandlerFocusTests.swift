import UIKit
import XCTest
@testable import ErmisChatUI

final class ComposerKeyboardHandlerFocusTests: XCTestCase {
    @MainActor
    func testKeyboardHideNotificationDoesNotDismissAnActiveComposer() {
        let parent = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let composer = ComposerViewController()
        let field = composer.textView
        parent.view.addSubview(field)
        field.frame = CGRect(x: 20, y: 100, width: 240, height: 46)
        XCTAssertTrue(field.becomeFirstResponder())
        let handler = ComposerKeyboardHandler(composerParentVC: parent, composerBottomConstraint: nil, composerVC: composer)
        handler.keyboardDidHide(Notification(name: UIResponder.keyboardDidHideNotification))
        drainMainQueue()
        XCTAssertTrue(field.isFirstResponder, "A software-keyboard hide must not revoke input focus, including hardware-keyboard editing.")
    }

    @MainActor
    func testQueuedHideDoesNotRevokeFocusAcquiredBeforeCallback() {
        let parent = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let composer = ComposerViewController()
        let field = composer.textView
        parent.view.addSubview(field)
        field.frame = CGRect(x: 20, y: 100, width: 240, height: 46)
        let handler = ComposerKeyboardHandler(composerParentVC: parent, composerBottomConstraint: nil, composerVC: composer)
        handler.keyboardDidHide(Notification(name: UIResponder.keyboardDidHideNotification))
        XCTAssertTrue(field.becomeFirstResponder())
        drainMainQueue()
        XCTAssertTrue(field.isFirstResponder, "A stale hide callback must not dismiss the newly focused input.")
    }

    @MainActor
    func testResignedComposerStillClearsItsCustomInput() {
        let parent = UIViewController()
        let composer = ComposerViewController()
        let field = composer.textView
        field.inputView = UIView()
        XCTAssertFalse(field.isFirstResponder)
        let handler = ComposerKeyboardHandler(composerParentVC: parent, composerBottomConstraint: nil, composerVC: composer)
        handler.keyboardDidHide(Notification(name: UIResponder.keyboardDidHideNotification))
        drainMainQueue()
        XCTAssertNil(field.inputView)
    }

    @MainActor
    private func drainMainQueue() {
        let completed = expectation(description: "Queued keyboard callback executed")
        DispatchQueue.main.async { completed.fulfill() }
        wait(for: [completed], timeout: 2)
    }
}
