//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit

extension NSObject {
    var classIdentifier: String {
        "\(type(of: self))"
    }
}

// Protocol that provides accessibility features
protocol AccessibilityView {
    // Identifier for view
    var accessibilityViewIdentifier: String { get }

    // This function is called once the view is being added to the view hierarchy
    func setAccessibilityIdentifier()
}

extension AccessibilityView where Self: UIView {
    var accessibilityViewIdentifier: String {
        classIdentifier
    }

    func setAccessibilityIdentifier() {
        accessibilityIdentifier = accessibilityViewIdentifier
    }
}

// A protocol to formalize the methods required, all component need to conform to this protocol.
public protocol BaseViewProtocol {
    /// Main point of customization for the view functionality.
    ///
    /// **It's called zero or one time(s) during the view's lifetime.** Calling super implementation is required.
    func setUp()

    /// Main point of customization for the view theme.
    ///
    /// **It's called multiple times during the view's lifetime.** The default implementation of this method is empty
    /// so calling `super` is usually not needed.
    func setUpTheme()

    /// Main point of customization for the view layout.
    ///
    /// **It's called zero or one time(s) during the view's lifetime.** Calling super is recommended but not required
    /// if you provide a complete layout for all subviews.
    func setUpUI()

    /// Main point of customizing the way the view updates its content.
    ///
    /// **It's called every time view's content changes.** Calling super is recommended but not required if you update
    /// the content of all subviews of the view.
    func contentDidChanged()
}

public extension BaseViewProtocol where Self: UIView {
    /// If the view is already in the view hierarchy it calls `contentDidChanged()`, otherwise does nothing.
    func updateContentIfNeeded() {
        if superview != nil {
            contentDidChanged()
        }
    }
}

public extension BaseViewProtocol where Self: UIViewController {
    /// If the view is already loaded it calls `contentDidChanged()`, otherwise does nothing.
    @MainActor
    func updateContentIfNeeded() {
        if isViewLoaded {
            contentDidChanged()
        }
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _View: UIView, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    fileprivate var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _CollectionViewCell: UICollectionViewCell, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _CollectionReusableView: UICollectionReusableView, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _Control: UIControl, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

/// Base class for overridable ImageView ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _ImageView: UIImageView, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _Button: UIButton, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _NavigationBar: UINavigationBar, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { setNeedsLayout() }
    open func setUpUI() { setNeedsLayout() }
    open func contentDidChanged() { setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

open class _ViewController: UIViewController, BaseViewProtocol {
    override open var next: UIResponder? {
        // When `self` is being added to the parent controller, the default `next` implementation returns nil
        // unless the `self.view` is added as a subview to `parent.view`. But `self.viewDidLoad` is
        // called before the transition finishes so the subviews are created from `Components.default`.
        // To prevent responder chain from being cutoff during `ViewController` lifecycle we fallback to parent.
        super.next ?? parent
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    /**
     A function that will be called on first launch of the `View` it's a function that can be used
     for any initial setup work required by the `View` such as setting delegates or data sources

     `setUp()` is an important function within the ViewController lifecycle
     Its responsibility is to set the delegates and also call `synchronize()`
     this will make sure your local & remote data is in sync.

     - Important: If you override this method without calling `super.setUp()`, it's essential
     to make sure `synchronize()` is called.
     */
    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { /* default empty implementation */ }
    open func setUpUI() { /* default empty implementation */ }
    open func contentDidChanged() { /* default empty implementation */ }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func viewWillLayoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.viewWillLayoutSubviews()
    }
}

/// Closure stack, used to reverse order of theme reloads on trait collection changes
private enum TraitCollectionReloadStack {
    private static var stack: [() -> Void] = []

    static func executePendingUpdates() {
        guard !stack.isEmpty else { return }
        let existingUpdates = stack
        stack.removeAll()
        existingUpdates.reversed().forEach { $0() }
    }

    static func push(_ closure: @escaping () -> Void) {
        stack.append(closure)
    }
}

/// Base class for overridable views ErmisChatUI provides.
/// All conformers will have ErmisChatUI theme settings by default.
open class _TableViewCell: UITableViewCell, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { /* default empty implementation */ }
    open func setUpUI() { /* default empty implementation */ }
    open func contentDidChanged() { /* default empty implementation */ }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}


open class _TableViewHeaderAndFooterView: UITableViewHeaderFooterView, BaseViewProtocol, AccessibilityView {
    // Flag for preventing multiple lifecycle methods calls.
    private var isInitialized: Bool = false

    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !isInitialized, superview != nil else { return }

        isInitialized = true

        setAccessibilityIdentifier()
        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { /* default empty implementation */ }
    open func setUpUI() { /* default empty implementation */ }
    open func contentDidChanged() { /* default empty implementation */ }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func layoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.layoutSubviews()
    }
}

open class _AlertViewController: UIAlertController, BaseViewProtocol {
    override open var next: UIResponder? {
        // When `self` is being added to the parent controller, the default `next` implementation returns nil
        // unless the `self.view` is added as a subview to `parent.view`. But `self.viewDidLoad` is
        // called before the transition finishes so the subviews are created from `Components.default`.
        // To prevent responder chain from being cutoff during `ViewController` lifecycle we fallback to parent.
        super.next ?? parent
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        setUp()
        setUpUI()
        setUpTheme()
        contentDidChanged()
    }

    /**
     A function that will be called on first launch of the `View` it's a function that can be used
     for any initial setup work required by the `View` such as setting delegates or data sources

     `setUp()` is an important function within the ViewController lifecycle
     Its responsibility is to set the delegates and also call `synchronize()`
     this will make sure your local & remote data is in sync.

     - Important: If you override this method without calling `super.setUp()`, it's essential
     to make sure `synchronize()` is called.
     */
    open func setUp() { /* default empty implementation */ }
    open func setUpTheme() { view.setNeedsLayout() }
    open func setUpUI() { view.setNeedsLayout() }
    open func contentDidChanged() { view.setNeedsLayout() }

    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard #available(iOS 12, *) else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }

        TraitCollectionReloadStack.push {
            self.setUpTheme()
            self.contentDidChanged()
        }
    }

    override open func viewWillLayoutSubviews() {
        TraitCollectionReloadStack.executePendingUpdates()
        super.viewWillLayoutSubviews()
    }
}
