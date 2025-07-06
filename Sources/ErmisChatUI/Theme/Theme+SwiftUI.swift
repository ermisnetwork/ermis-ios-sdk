//
// Copyright 2025 Ermis Inc.
//

import Combine
import ErmisChat
import SwiftUI

extension Theme {
    /// Used to initialize `Components` as `ObservableObject`.
    public var asObservableObject: ObservableObject { .init(self) }

    @dynamicMemberLookup
    /// `Components` represented as `ObservableObject` class for SwiftUI requirements.
    public class ObservableObject: SwiftUI.ObservableObject {
        private let wrappedAppearance: Theme

        public subscript<T>(dynamicMember keyPath: KeyPath<Theme, T>) -> T {
            wrappedAppearance[keyPath: keyPath]
        }

        fileprivate init(_ wrappedAppearance: Theme) {
            self.wrappedAppearance = wrappedAppearance
        }
    }
}

/// Modifier for setting `Components` environment object.
private struct SwiftUIAppearance: ViewModifier {
    /// Custom `ObservableObject` of `components`
    private let theme: Theme

    public init(_ theme: Theme) {
        self.theme = theme
    }

    public func body(content: Content) -> some View {
        content.environmentObject(theme.asObservableObject)
    }
}

public extension View {
    /// Sets up custom `Components`.
    func setUpTheme(_ theme: Theme = .default) -> some View {
        modifier(SwiftUIAppearance(theme))
    }
}
