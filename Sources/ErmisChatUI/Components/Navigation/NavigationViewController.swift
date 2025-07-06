//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The navigation controller with navigation bar of `ChatNavigationBar` type.
open class NavigationViewController: UINavigationController {
    public required init(
        rootViewController: UIViewController,
        navigationBarClass: ChatNavigationBar.Type = ChatNavigationBar.self,
        toolbarClass: AnyClass? = nil
    ) {
        super.init(navigationBarClass: navigationBarClass, toolbarClass: toolbarClass)
        viewControllers = [rootViewController]
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
}
