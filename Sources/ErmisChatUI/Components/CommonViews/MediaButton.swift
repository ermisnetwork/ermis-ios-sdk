//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A button that is being used in the VoiceRecording flow and represents a functionality on the playback.
/// - Note: As a MediaButton the theme is common between light/dark mode.
open class MediaButton: _Button, ThemeProvider {
    override open var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
            ? theme.colors.surfaceContainerHigh
            : theme.colors.white
        }
    }

    // MARK: - Lifecycle

    override open func setUpTheme() {
        super.setUpTheme()

        tintColor = theme.colors.black
        setTitleColor(theme.colors.black, for: .normal)
        backgroundColor = isHighlighted
        ? theme.colors.surfaceContainerHigh
            : theme.colors.white
        layer.shadowColor = tintColor.cgColor
    }

    // MARK: - Interaction

    override open func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        super.touchesBegan(touches, with: event)
        isHighlighted = true
    }

    override open func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        super.touchesEnded(touches, with: event)
        isHighlighted = false
    }

    override open func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        super.touchesCancelled(touches, with: event)
        isHighlighted = false
    }
}
