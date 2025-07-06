//
// Copyright 2025 Ermis Inc.
//

import Combine
import ErmisChat
import SwiftUI

/// Protocol of `MessageContentView` wrapper for use in SwiftUI.
public protocol MessageContentViewSwiftUIView: View {
    init(dataSource: MessageContentView.ObservedObject<Self>)
}

extension MessageContentView {
    /// Data source of `MessageContentView` represented as `ObservedObject`.
    public typealias ObservedObject<Content: SwiftUIView> = SwiftUIWrapper<Content>

    /// `MessageContentView` represented in SwiftUI.
    public typealias SwiftUIView = MessageContentViewSwiftUIView

    /// SwiftUI wrapper of `MessageContentView`.
    /// Servers to wrap custom SwiftUI view as a UIKit view so it can be easily injected into `Components`.
    public class SwiftUIWrapper<Content: SwiftUIView>: MessageContentView, ObservableObject {
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
