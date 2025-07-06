//
// Copyright 2025 Ermis Inc.
//

import UIKit

open
class ChannelConditionRequiredViewController: _ViewController, UIProvider {
    open private (set) lazy var channelConditionRequiredView = components.channelConditionRequiredView.init().withoutAutoresizingMaskConstraints

    open private (set) lazy var bgView = UIView().withoutAutoresizingMaskConstraints

    open var content: ChannelConditionRequiredView.Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    var delegate: ChannelConditionRequiredAlertViewDelegate? {
        get {
            return channelConditionRequiredView.delegate
        }
        set {
            channelConditionRequiredView.delegate = newValue
        }
    }

    open override func setUp() {
        bgView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onBgViewDidTapped)))
        channelConditionRequiredView.layer.cornerRadius = 4
        channelConditionRequiredView.layer.borderWidth = 1
    }

    open override func setUpUI() {
        view.addSubview(bgView)
        bgView.pin(to: view.safeAreaLayoutGuide)

        view.addSubview(channelConditionRequiredView)
        channelConditionRequiredView.pin(anchors: [.centerX, .centerY], to: bgView)
        channelConditionRequiredView.pin(anchors: [.leading], to: bgView, contant: 16)
        channelConditionRequiredView.topAnchor.pin(greaterThanOrEqualTo: bgView.topAnchor, constant: 32).isActive = true
    }

    open override func setUpTheme() {
        bgView.backgroundColor = .clear
        channelConditionRequiredView.layer.borderColor = theme.colors.outline.cgColor
        channelConditionRequiredView.backgroundColor = theme.colors.surface
    }

    open override func contentDidChanged() {
        channelConditionRequiredView.content = content
    }

    // MARK: - Action
    @objc
    private func onBgViewDidTapped() {
        dismiss(animated: true)
    }
}
