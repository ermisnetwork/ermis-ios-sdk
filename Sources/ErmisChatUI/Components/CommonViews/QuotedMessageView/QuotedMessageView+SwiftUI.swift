//
// Copyright 2025 Ermis Inc.
//

import Combine
import ErmisChat
import SwiftUI

/// Protocol of `QuotedMessageView` wrapper for use in SwiftUI.
public protocol QuotedMessageViewSwiftUIView: View {
    init(dataSource: QuotedMessageView.ObservedObject<Self>)
}

extension QuotedMessageView {
    /// Data source of `QuotedMessageView` represented as `ObservedObject`.
    public typealias ObservedObject<Content: SwiftUIView> = SwiftUIWrapper<Content>

    /// `QuotedMessageView` represented in SwiftUI.
    public typealias SwiftUIView = QuotedMessageViewSwiftUIView

    /// SwiftUI wrapper of `QuotedMessageView`.
    public class SwiftUIWrapper<Content: SwiftUIView>: QuotedMessageView, ObservableObject {
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
