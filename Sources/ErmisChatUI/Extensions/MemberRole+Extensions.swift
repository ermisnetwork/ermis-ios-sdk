//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

extension MemberRole {
    public var title: String {
        switch self {
        case .member:
            return L10n.MemberRole.member
        case .admin:
            return L10n.MemberRole.admin
        case .owner:
            return L10n.MemberRole.owner
        case .pending:
            return L10n.MemberRole.pending
        case .moderator:
            return L10n.MemberRole.moderator
        case .skipped:
            return L10n.MemberRole.skipped
        case .rejected:
            return L10n.MemberRole.rejected
        default:
            return L10n.MemberRole.unknown
        }
    }
}
