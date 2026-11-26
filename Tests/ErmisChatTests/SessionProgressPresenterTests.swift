import XCTest
import UIKit
@testable import ErmisChat
@testable import ErmisChatUI

final class SessionProgressPresenterTests: XCTestCase {
    @MainActor private func host() -> (UIWindow, UIViewController, UIButton) {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        let action = UIButton(frame: CGRect(x: 0, y: 250, width: 390, height: 60))
        controller.view.addSubview(action); controller.view.layoutIfNeeded()
        return (window, controller, action)
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func panels(_ host: UIViewController) -> [UIView] {
        descendants(host.view).filter { $0.accessibilityIdentifier?.hasPrefix("session-progress-") == true }
    }
    @MainActor private func presenter(_ p: SessionSyncProgress) -> SessionProgressPresenter {
        SessionProgressPresenter(currentProgress: { p }, localized: {
            switch $0 {
            case "session_progress.channels_syncing": return "Đang đồng bộ · %1$d/%2$d kênh đã sẵn sàng"
            case "session_progress.channels_partial": return "Cần thử lại · %1$d/%2$d kênh đã sẵn sàng"
            case "session_progress.channels_done": return "Đã đồng bộ · %1$d/%2$d kênh đã sẵn sàng"
            default: return $0
            }
        })
    }

    @MainActor func testForegroundHistoryShowsOnceForItsEncryptedRoute() throws {
        let progress = SessionSyncProgress(), ui = presenter(progress)
        let (window, chat, _) = host()
        let first = try XCTUnwrap(progress.beginHistoryPage(cid: "team:secure"))
        ui.show(on: chat, channelId: "team:secure", isEncrypted: { true })
        XCTAssertEqual(panels(chat).count, 1)
        ui.show(on: chat, channelId: "topic:standard", isEncrypted: { false })
        XCTAssertTrue(panels(chat).isEmpty)
        ui.show(on: chat, channelId: "other", isEncrypted: { true })
        XCTAssertTrue(panels(chat).isEmpty)
        progress.endHistoryPage(first)
        XCTAssertNil(progress.snapshot)
        XCTAssertNil(progress.beginHistoryPage(cid: "team:secure"))
        progress.invalidate()
        let replacement = try XCTUnwrap(progress.beginHistoryPage(cid: "team:secure"))
        progress.endHistoryPage(first)
        XCTAssertEqual(progress.snapshot?.cycleId, replacement)
        withExtendedLifetime(window) {}
    }

    @MainActor func testPreparationHidesFractionsUntilReadinessStartsOnTheSamePopup() throws {
        let p = SessionSyncProgress(), ui = presenter(p)
        let (window, list, action) = host()
        p.record(scope: "standard|plain", result: .ready, owner: p.owner)
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["plain": "standard|plain", "secure": "secure"], retry: {})
        ui.show(on: list); list.view.layoutIfNeeded()
        var labels = descendants(list.view).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("session_progress.preparing")); XCTAssertFalse(labels.contains { $0.contains("1/2") })
        let original = try XCTUnwrap(panels(list).first)
        let cycle = p.snapshot?.cycleId
        XCTAssertTrue(window.hitTest(CGPoint(x: 20, y: 270), with: nil) === action)
        p.startReadiness(owner: p.owner); ui.refresh()
        labels = descendants(list.view).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("Đang đồng bộ · 1/2 kênh đã sẵn sàng"))
        XCTAssertTrue(panels(list).first === original); XCTAssertEqual(p.snapshot?.cycleId, cycle)
        withExtendedLifetime(window) {}
    }
    @MainActor func testOneNonmodalPopupMovesBetweenListAndChannelWithoutResetAndDismissalDoesNotCancelWork() throws {
        let p = SessionSyncProgress(), ui = presenter(p)
        let (window, list, action) = host()
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a": "a", "b": "b"], retry: {})
        p.record(scope: "a", result: .ready, owner: p.owner)
        p.startReadiness(owner: p.owner)
        ui.show(on: list); ui.refresh(); list.view.layoutIfNeeded()
        XCTAssertEqual(panels(list).count, 1)
        XCTAssertTrue(descendants(list.view).compactMap { ($0 as? UILabel)?.text }.contains("Đang đồng bộ · 1/2 kênh đã sẵn sàng"))
        XCTAssertTrue(window.hitTest(CGPoint(x: 20, y: 270), with: nil) === action, "Controls outside the small popup remain interactive")
        XCTAssertNil(list.presentedViewController)
        let cycle = p.snapshot?.cycleId
        ui.hide(from: list)
        let chat = UIViewController(); window.rootViewController = chat
        let messages = UIView(frame: CGRect(x: 0, y: 120, width: 390, height: 600)); chat.view.addSubview(messages)
        ui.show(on: chat, anchor: messages); chat.view.layoutIfNeeded()
        XCTAssertEqual(panels(list).count, 0); XCTAssertEqual(panels(chat).count, 1)
        XCTAssertEqual(p.snapshot?.cycleId, cycle)
        ui.dismissPanel()
        ui.hide(from: chat); window.rootViewController = list; ui.show(on: list)
        XCTAssertEqual(panels(list).count, 0)
        p.record(scope: "b", result: .ready, owner: p.owner); ui.refresh()
        XCTAssertEqual(p.snapshot?.status, "done")
        XCTAssertEqual(p.snapshot?.readyChannels, 2)
        XCTAssertEqual(panels(list).count, 0, "Dismissal hides presentation for this cycle only")
        withExtendedLifetime(window) {}
    }

    @MainActor func testOldCompletionTimerCannotHideReplacementCycleEvenWhenItAlsoCompletes() throws {
        let p = SessionSyncProgress(), ui = presenter(p)
        let (window, list, _) = host()
        var timers: [() -> Void] = []
        ui.scheduleCompletion = { timers.append($0) }
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["old": "old"], retry: {})
        p.record(scope: "old", result: .ready, owner: p.owner)
        ui.show(on: list)
        XCTAssertEqual(timers.count, 1)
        p.invalidate()
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["new": "new"], retry: {})
        ui.refresh()
        p.record(scope: "new", result: .ready, owner: p.owner); ui.refresh()
        XCTAssertEqual(timers.count, 2)
        timers[0]()
        XCTAssertEqual(panels(list).count, 1)
        timers[1]()
        XCTAssertEqual(panels(list).count, 0)
        withExtendedLifetime(window) {}
    }

    @MainActor func testPartialShowsTruthfulCountsRetryAndAccessibilityWithoutAutoHideOrSpinner() throws {
        let p = SessionSyncProgress(), ui = presenter(p)
        let (window, list, _) = host()
        var timers = 0, retries = 0
        ui.scheduleCompletion = { _ in timers += 1 }
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: ["a": "a", "b": "b"], retry: { retries += 1 })
        p.record(scope: "a", result: .ready, owner: p.owner)
        p.record(scope: "b", result: .blocked, owner: p.owner)
        ui.show(on: list)
        XCTAssertEqual(timers, 0)
        let all = descendants(list.view)
        let label = try XCTUnwrap(all.compactMap { $0 as? UILabel }.first { $0.text?.hasPrefix("Cần thử lại") == true })
        XCTAssertEqual(label.text, "Cần thử lại · 1/2 kênh đã sẵn sàng")
        XCTAssertEqual(label.accessibilityLabel, label.text)
        XCTAssertTrue(label.adjustsFontForContentSizeCategory)
        XCTAssertTrue(all.compactMap { $0 as? UIActivityIndicatorView }.allSatisfy { !$0.isAnimating })
        XCTAssertTrue(all.compactMap { $0 as? UIButton }.contains { $0.title(for: .normal) == "session_progress.retry" && !$0.isHidden })
        ui.retryWork(); ui.retryWork(); XCTAssertEqual(retries, 1)
        withExtendedLifetime(window) {}
    }

    @MainActor func testInventoryPreparingDoesNotDisplayTemporaryZeroDenominator() throws {
        let p = SessionSyncProgress(), ui = presenter(p)
        let (window, list, _) = host()
        _ = p.beginInventory(); ui.show(on: list)
        XCTAssertEqual(panels(list).count, 1)
        XCTAssertTrue(descendants(list.view).compactMap { ($0 as? UILabel)?.text }.contains("session_progress.inventory"))
        XCTAssertNil(p.snapshot?.totalChannels)
        withExtendedLifetime(window) {}
    }

    @MainActor func testForegroundMetadataRefreshKeepsCompletionTimerAndDoesNotReplayHiddenPopup() throws {
        let p = SessionSyncProgress(), ui = presenter(p)
        let (window, list, _) = host()
        var timers: [() -> Void] = []
        ui.scheduleCompletion = { timers.append($0) }
        let channels = ["a": "a"]
        p.finishInventory(try XCTUnwrap(p.beginInventory()), channels: channels, retry: {})
        p.record(scope: "a", result: .ready, owner: p.owner)
        ui.show(on: list)
        let refresh = try XCTUnwrap(p.beginInventory())
        ui.refresh(replayTerminal: false)
        XCTAssertEqual(timers.count, 1, "Foreground refresh cannot restart the completion timer")
        timers[0]()
        XCTAssertEqual(panels(list).count, 0)
        p.finishInventory(refresh, channels: channels, retry: {})
        ui.refresh(replayTerminal: false)
        XCTAssertEqual(panels(list).count, 0, "A hidden completed cycle stays hidden on foreground")
        XCTAssertEqual(timers.count, 1)
        withExtendedLifetime(window) {}
    }
}
