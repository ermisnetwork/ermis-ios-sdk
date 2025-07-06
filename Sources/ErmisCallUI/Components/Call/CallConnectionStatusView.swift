//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import ErmisCall
import ErmisChatUI

open class CallConnectionStatusView: _View, ThemeProvider {
    public private(set) lazy var contentStackView =
    ContainerStackView(axis: .vertical,
                       alignment: .center,
                       spacing: 8,
                       distribution: .natural)
    .withoutAutoresizingMaskConstraints
    public private(set) lazy var noticeLabel = createNoiticeLabel()
    public private(set) lazy var indicator = createLoadingIndicator()

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    open override func setUp() {
        super.setUp()
    }

    open override func setUpUI() {
        super.setUpUI()
        addSubview(contentStackView)
        contentStackView.pin(to: self)
        contentStackView.addArrangedSubviews([noticeLabel, indicator])
    }

    open override func setUpTheme() {
        super.setUpTheme()
        contentStackView.backgroundColor = .clear
        noticeLabel.textColor = theme.colors.white
        noticeLabel.font = theme.fonts.body
        indicator.tintColor = theme.colors.white
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        guard let content else {
            hide()
            return
        }
        switch content.connectionStatus {
        case .normal:
            hide()
        case .lowConnection:
            noticeLabel.text = L10n.Call.Connection.lowConnection
            show()
        case .yourConnectionIsBeingEstablished:
            noticeLabel.text = L10n.Call.Connection.yourConnectionUnstable
            show()
        case .theirConnectionIsBeingEstablished(let userIds):
            noticeLabel.text = L10n.Call.Connection.otherConnectionUnstable(content.callTitle ?? "Other")
            show()
        case .none:
            hide()
        }
    }

    public func show() {
        self.isHidden = false
        self.indicator.startAnimating()
    }

    public func hide() {
        self.indicator.stopAnimating()
        self.isHidden = true
    }
}
// MARK: - CreateUI
extension CallConnectionStatusView {
    private func createLoadingIndicator() -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
            .withoutAutoresizingMaskConstraints
        return indicator
    }

    private func createNoiticeLabel() -> UILabel {
        let label = UILabel().withoutAutoresizingMaskConstraints
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }
}
// MARK: - Content
extension CallConnectionStatusView {
    public struct Content {
        public var connectionStatus: CallConnectionStatus?
        public var callTitle: String?
    }
}
