//
// Copyright 2025 Ermis Inc.
//

import UIKit

public
extension UIView {
    func addSubviews(_ subviews: [UIView]) {
        subviews.forEach({
            addSubview($0)
        })
    }
    // MARK: - `embed` family of helpers

    @objc func embed(_ subview: UIView, insets: NSDirectionalEdgeInsets = .zero) {
        addSubview(subview)

        NSLayoutConstraint.activate([
            subview.leadingAnchor.pin(equalTo: leadingAnchor, constant: insets.leading),
            subview.trailingAnchor.pin(equalTo: trailingAnchor, constant: -insets.trailing),
            subview.topAnchor.pin(equalTo: topAnchor, constant: insets.top),
            subview.bottomAnchor.pin(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }

    func pin(anchors: [LayoutAnchorName] = [.top, .leading, .bottom, .trailing],
             to view: UIView,
             contant: CGFloat = 0) {
        anchors
            .map { $0.makeConstraint(fromView: self, toView: view, constant: contant) }
            .forEach { $0.isActive = true }
    }

    func pin(anchors: [LayoutAnchorName] = [.top, .leading, .bottom, .trailing],
             to layoutGuide: UILayoutGuide,
             constant: CGFloat = 0) {
        anchors
            .compactMap { $0.makeConstraint(fromView: self, toLayoutGuide: layoutGuide, constant: constant) }
            .forEach { $0.isActive = true }
    }

    func pin(anchors: [LayoutAnchorName] = [.width, .height], to constant: CGFloat) {
        anchors
            .compactMap { $0.makeConstraint(fromView: self, constant: constant) }
            .forEach { $0.isActive = true }
    }

    func pin(anchors: [LayoutAnchorName] = [.width, .height], to view: UIView, constant: CGFloat = 0, multipler: CGFloat = 1) {
        anchors
            .compactMap { $0.makeConstraint(fromView: self, toView: view, constant: constant, multiplier: multipler) }
            .forEach { $0.isActive = true }
    }

    var withoutAutoresizingMaskConstraints: Self {
        translatesAutoresizingMaskIntoConstraints = false
        return self
    }

    @discardableResult
    func withAccessibilityIdentifier(identifier: String) -> Self {
        accessibilityIdentifier = identifier
        return self
    }

    var isVisible: Bool {
        get { !isHidden }
        set { isHidden = !newValue }
    }

    func setAnimatedly(hidden: Bool) {
        Animate({
            self.alpha = hidden ? 0.0 : 1.0
            self.isHidden = hidden
        }) { _ in
            self.isHidden = hidden
        }
    }

    /// Returns `UIView` that is flexible along defined `axis`.
    static func spacer(axis: NSLayoutConstraint.Axis) -> UIView {
        UIView().flexible(axis: axis)
    }
}

public
enum LayoutAnchorName {
    case bottom
    case centerX
    case centerY
    case firstBaseline
    case height
    case lastBaseline
    case leading
    case left
    case right
    case top
    case trailing
    case width

    func makeConstraint(fromView: UIView, toView: UIView, constant: CGFloat = 0, multiplier: CGFloat = 1) -> NSLayoutConstraint {
        switch self {
        case .bottom:
            return fromView.bottomAnchor.pin(equalTo: toView.bottomAnchor, constant: constant)
        case .centerX:
            return fromView.centerXAnchor.pin(equalTo: toView.centerXAnchor, constant: constant)
        case .centerY:
            return fromView.centerYAnchor.pin(equalTo: toView.centerYAnchor, constant: constant)
        case .firstBaseline:
            return fromView.firstBaselineAnchor.pin(equalTo: toView.firstBaselineAnchor, constant: constant)
        case .height:
            return fromView.heightAnchor.pin(equalTo: toView.heightAnchor, multiplier: multiplier, constant: constant)
        case .lastBaseline:
            return fromView.lastBaselineAnchor.pin(equalTo: toView.lastBaselineAnchor, constant: constant)
        case .leading:
            return fromView.leadingAnchor.pin(equalTo: toView.leadingAnchor, constant: constant)
        case .left:
            return fromView.leftAnchor.pin(equalTo: toView.leftAnchor, constant: constant)
        case .right:
            return fromView.rightAnchor.pin(equalTo: toView.rightAnchor, constant: constant)
        case .top:
            return fromView.topAnchor.pin(equalTo: toView.topAnchor, constant: constant)
        case .trailing:
            return fromView.trailingAnchor.pin(equalTo: toView.trailingAnchor, constant: constant)
        case .width:
            return fromView.widthAnchor.pin(equalTo: toView.widthAnchor, multiplier: multiplier, constant: constant)
        }
    }

    func makeConstraint(fromView: UIView, toLayoutGuide: UILayoutGuide, constant: CGFloat = 0) -> NSLayoutConstraint? {
        switch self {
        case .bottom:
            return fromView.bottomAnchor.pin(equalTo: toLayoutGuide.bottomAnchor, constant: constant)
        case .centerX:
            return fromView.centerXAnchor.pin(equalTo: toLayoutGuide.centerXAnchor, constant: constant)
        case .centerY:
            return fromView.centerYAnchor.pin(equalTo: toLayoutGuide.centerYAnchor, constant: constant)
        case .height:
            return fromView.heightAnchor.pin(equalTo: toLayoutGuide.heightAnchor, constant: constant)
        case .leading:
            return fromView.leadingAnchor.pin(equalTo: toLayoutGuide.leadingAnchor, constant: constant)
        case .left:
            return fromView.leftAnchor.pin(equalTo: toLayoutGuide.leftAnchor, constant: constant)
        case .right:
            return fromView.rightAnchor.pin(equalTo: toLayoutGuide.rightAnchor, constant: constant)
        case .top:
            return fromView.topAnchor.pin(equalTo: toLayoutGuide.topAnchor, constant: constant)
        case .trailing:
            return fromView.trailingAnchor.pin(equalTo: toLayoutGuide.trailingAnchor, constant: constant)
        case .width:
            return fromView.widthAnchor.pin(equalTo: toLayoutGuide.widthAnchor, constant: constant)
        case .firstBaseline, .lastBaseline:
            // TODO: Log warning? Error?
            return nil
        }
    }

    func makeConstraint(fromView: UIView, constant: CGFloat) -> NSLayoutConstraint? {
        switch self {
        case .height:
            return fromView.heightAnchor.pin(equalToConstant: constant)
        case .width:
            return fromView.widthAnchor.pin(equalToConstant: constant)
        default:
            // TODO: Log warning? Error?
            return nil
        }
    }
}

extension UIView {
    /// According to this property, you can differ whether the current language is `rightToLeft`
    /// and setup actions according to it.
    var currentLanguageIsRightToLeftDirection: Bool {
        traitCollection.layoutDirection == .rightToLeft
    }

    func makeConstraint(attribute attribute1: NSLayoutConstraint.Attribute,
                        relatedBy relation: NSLayoutConstraint.Relation = .equal,
                        toItem view2: Any?,
                        attribute attribute2: NSLayoutConstraint.Attribute,
                        multiplier: CGFloat = 1,
                        constant: CGFloat = 0) -> NSLayoutConstraint {
        return NSLayoutConstraint(item: self,
                                  attribute: attribute1,
                                  relatedBy: relation,
                                  toItem: view2,
                                  attribute: attribute2,
                                  multiplier: multiplier,
                                  constant: constant)
    }
}
