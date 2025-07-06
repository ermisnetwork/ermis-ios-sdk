//
// Copyright 2025 Ermis Inc.
//

import Combine
import ErmisChat
import SwiftUI

/// Protocol of `ChannelUnreadCountView` wrapper for use in SwiftUI.
public protocol ChannelUnreadCountViewSwiftUIView: View {
    init(dataSource: UnreadCountView.ObservedObject<Self>)
}

extension UnreadCountView {
    /// Data source of `ChannelUnreadCountView` represented as `ObservedObject`.
    public typealias ObservedObject<Content: SwiftUIView> = SwiftUIWrapper<Content>

    /// `ChannelUnreadCountView` represented in SwiftUI.
    public typealias SwiftUIView = ChannelUnreadCountViewSwiftUIView

    /// SwiftUI wrapper of `ChannelUnreadCountView`.
    /// Servers to wrap custom SwiftUI view as a UIKit view so it can be easily injected into `Components`.
    public class SwiftUIWrapper<Content: SwiftUIView>: UnreadCountView, ObservableObject {
        var hostingController: UIViewController?

        override public var intrinsicContentSize: CGSize {
            hostingController?.view.intrinsicContentSize ?? super.intrinsicContentSize
        }

        override public func setUp() {
            super.setUp()

            let view = Content(dataSource: self)
                .environmentObject(components.asObservableObject)
                .environmentObject(theme.asObservableObject)
            hostingController = UIHostingController(rootView: view)
            hostingController!.view.backgroundColor = .clear
        }

        override public func setUpUI() {
            hostingController!.view.translatesAutoresizingMaskIntoConstraints = false
            embed(hostingController!.view)
        }

        override public func contentDidChanged() {
            objectWillChange.send()
        }
    }
}
