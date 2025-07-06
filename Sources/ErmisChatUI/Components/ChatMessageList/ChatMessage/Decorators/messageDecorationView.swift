//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit

/// A type that describes where a decoration will be placed
public enum MessageDecorationType: Equatable {
    /// A header decoration is being placed above the
    /// cell's content
    case header

    /// A footer decoration is being placed below the
    /// cell's content
    case footer
}

/// The view that displays any header or footer decorations above & below a
/// MessageCell.
open class MessageCellHeaderFooterView: _View {
    public static var reuseId: String { "\(self)" }
}
