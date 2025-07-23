//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

/// A component that presents the active recording time during a recording flow.
open class RecordingIndicatorView: _View, UIProvider {
    public var content: TimeInterval = 0 {
        didSet { updateContentIfNeeded() }
    }

    // MARK: - UI Components

    /// The main container where all components will be added into.
    open private(set) lazy var container: UIStackView = .init()
        .withoutAutoresizingMaskConstraints

    /// The imageView that shows by default a mic image, to indicate to the user we are currently
    /// recording audio.
    open private(set) lazy var recordingIndicator: UIImageView = .init()
        .withoutAutoresizingMaskConstraints

    /// The label that shows the duration of the active recording.
    open private(set) lazy var durationLabel: UILabel = UILabel()
        .withBidirectionalLanguagesSupport
        .withoutAutoresizingMaskConstraints

    // MARK: - Lifecycle

    override open func setUpUI() {
        super.setUpUI()
        recordingIndicator.pin(anchors: [.width], to: 35)
        recordingIndicator.pin(anchors: [.height], to: 46)
        durationLabel.pin(anchors: [.height], to: 46)

        container.axis = .horizontal
        container.spacing = 5
        container.addArrangedSubview(recordingIndicator)
        container.addArrangedSubview(durationLabel)

        embed(container, insets: .zero)
    }

    override open func setUpTheme() {
        super.setUpTheme()
        recordingIndicator.contentMode = .center
        recordingIndicator.image = theme.icons.mic.tinted(with: theme.colors.error)
        durationLabel.textColor = theme.colors.subTitleTextLow
        durationLabel.font = .monospacedDigitSystemFont(ofSize: theme.fonts.footnote.pointSize, weight: .medium)
    }

    override open func contentDidChanged() {
        durationLabel.text = formatters.videoDuration.format(content)
    }
}
