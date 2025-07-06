//
// Copyright 2025 Ermis Inc.
//

import Combine
import ErmisChat
import SwiftUI

/// Protocol of `ChannelAvatarView` wrapper for use in SwiftUI.
public protocol ChannelAvatarViewSwiftUIView: View {
    init(dataSource: ChannelAvatarView.ObservedObject<Self>)
}

extension ChannelAvatarView {
    /// Data source of `ChannelAvatarView` represented as `ObservedObject`.
    public typealias ObservedObject<Content: SwiftUIView> = SwiftUIWrapper<Content>

    /// `ChannelAvatarView` represented in SwiftUI.
    public typealias SwiftUIView = ChannelAvatarViewSwiftUIView

    /// SwiftUI wrapper of `ChannelAvatarView`.
    public class SwiftUIWrapper<Content: SwiftUIView>: ChannelAvatarView, ObservableObject {
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
            hostingController?.view.backgroundColor = .clear
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
