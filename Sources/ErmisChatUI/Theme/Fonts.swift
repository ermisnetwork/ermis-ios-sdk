//
// Copyright 2025 Ermis Inc.
//

import UIKit.UIFont

public extension Theme {
    struct Fonts {
        public var largetitle = UIFont.preferredFont(forTextStyle: .largeTitle)
        public var title = UIFont.preferredFont(forTextStyle: .title1)
        public var title2 = UIFont.preferredFont(forTextStyle: .title2)
        public var title3 = UIFont.preferredFont(forTextStyle: .title3)
        public var headline = UIFont.preferredFont(forTextStyle: .headline)
        public var body = UIFont.preferredFont(forTextStyle: .body)
        public var callout = UIFont.preferredFont(forTextStyle: .callout)
        public var subheadline = UIFont.preferredFont(forTextStyle: .subheadline)
        public var footnote = UIFont.preferredFont(forTextStyle: .footnote)
        public var caption1 = UIFont.preferredFont(forTextStyle: .caption1)
        public var caption2 = UIFont.preferredFont(forTextStyle: .caption2)

        public var emoji = UIFont.preferredFont(forTextStyle: .body).withSize(50)
    }
}
