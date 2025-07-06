//
// Copyright 2025 Ermis Inc.
//

import Combine
import ErmisChat
import SwiftUI

/// Protocol of `ChannelListItemView` wrapper for use in SwiftUI.
public protocol ChannelListItemViewSwiftUIView: View {
    init(dataSource: ChannelListItemView.ObservedObject<Self>)
}

extension ChannelListItemView {
    /// Data source of `ChannelListItemView` represented as `ObservedObject`.
    public typealias ObservedObject<Content: SwiftUIView> = SwiftUIWrapper<Content>

    /// `ChannelListItemView` represented in SwiftUI.
    public typealias SwiftUIView = ChannelListItemViewSwiftUIView

    /// SwiftUI wrapper of `ChannelListItemView`.
    /// Servers to wrap custom SwiftUI view as a UIKit view so it can be easily injected into `Components`.
    public class SwiftUIWrapper<Content: SwiftUIView>: ChannelListItemView, ObservableObject {
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
