import XCTest
import UIKit
import ErmisSharedUI
@testable import ErmisChatUI

final class PresentationLocalizationTests: XCTestCase {
    @MainActor
    private func withLanguage(_ code: String, _ body: () -> Void) {
        let oldProvider = Theme.default.localizationProvider
        let oldLocale = Theme.default.localizationLocale
        defer {
            Theme.default.localizationProvider = oldProvider
            Theme.default.localizationLocale = oldLocale
        }
        Theme.default.localizationLocale = Locale(identifier: code)
        Theme.default.localizationProvider = { key, table in
            for bundle in [Bundle.ermisChatUI, Bundle.ermisSharedUI] {
                if let path = bundle.path(forResource: code, ofType: "lproj"), let localized = Bundle(path: path) {
                    let value = localized.localizedString(forKey: key, value: key, table: table)
                    if value != key { return value }
                }
            }
            return key
        }
        body()
    }

    @MainActor func testPluralCountsAndUserTextFollowSelectedLanguage() {
        withLanguage("en") {
            XCTAssertEqual(ErmisChatUI.L10n.ui("poll.voter-count", 1), "1 voter")
            XCTAssertEqual(ErmisChatUI.L10n.ui("poll.voter-count", 2), "2 voters")
            XCTAssertEqual(ErmisChatUI.L10n.ui("poll.choice-votes", "User answer", 2), "User answer · 2 votes")
        }
        withLanguage("vi") {
            XCTAssertEqual(ErmisChatUI.L10n.ui("poll.voter-count", 2), "2 người bình chọn")
            XCTAssertEqual(ErmisChatUI.L10n.ui("poll.choice-votes", "User answer", 2), "User answer · 2 phiếu")
        }
    }

    @MainActor func testExistingEmptyViewRefreshesWithoutRecreatingHierarchy() {
        let host = UIView()
        let empty = ErmisSharedUI.ChannelListEmptyView()
        host.addSubview(empty)
        withLanguage("en") {
            empty.contentDidChanged()
            XCTAssertEqual(empty.actionButton.title(for: .normal), ErmisSharedUI.L10n.ChannelList.Empty.button)
        }
        let original = ObjectIdentifier(empty)
        withLanguage("vi") {
            empty.contentDidChanged()
            XCTAssertEqual(empty.actionButton.title(for: .normal), ErmisSharedUI.L10n.ChannelList.Empty.button)
            XCTAssertFalse(empty.titleLabel.text?.isEmpty ?? true)
        }
        XCTAssertEqual(ObjectIdentifier(host.subviews[0]), original)
    }

    @MainActor func testTextAndSurfaceHaveContrastInBothAppearances() {
        func luminance(_ color: UIColor, _ traits: UITraitCollection) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ x: CGFloat) -> Double { x <= 0.04045 ? Double(x / 12.92) : pow(Double((x + 0.055) / 1.055), 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let surface = luminance(Theme.default.colors.surface, traits)
            let text = luminance(Theme.default.colors.text, traits)
            XCTAssertGreaterThanOrEqual((max(surface, text) + 0.05) / (min(surface, text) + 0.05), 4.5)
        }
    }
}
