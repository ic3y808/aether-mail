import SwiftUI
import EmailKit

// Canonical folder ordering + icons, so every provider's mailboxes line up the
// same way regardless of how they're named on the server.
extension FolderRole {
    var sortRank: Int {
        switch self {
        case .inbox:   return 0
        case .drafts:  return 1
        case .sent:    return 2
        case .archive: return 3
        case .flagged: return 4
        case .junk:    return 5
        case .trash:   return 6
        case .all:     return 7
        case .other:   return 8
        }
    }
    var icon: String {
        switch self {
        case .inbox:   return "tray"
        case .drafts:  return "doc"
        case .sent:    return "paperplane"
        case .archive: return "archivebox"
        case .flagged: return "flag"
        case .junk:    return "xmark.bin"
        case .trash:   return "trash"
        case .all:     return "tray.2"
        case .other:   return "folder"
        }
    }
}

// Provider identity — an SF Symbol and a brand-ish tint for account rows/avatars.
extension MailProvider {
    var icon: String {
        switch self {
        case .icloud:  return "icloud.fill"
        case .gmail:   return "envelope.fill"
        case .outlook: return "envelope.fill"
        case .proton:  return "lock.fill"
        case .custom:  return "server.rack"
        }
    }
    var tint: Color {
        switch self {
        case .icloud:  return Color(red: 0.20, green: 0.60, blue: 0.98)
        case .gmail:   return Color(red: 0.92, green: 0.26, blue: 0.21)
        case .outlook: return Color(red: 0.0,  green: 0.46, blue: 0.84)
        case .proton:  return Color(red: 0.42, green: 0.35, blue: 0.80)
        case .custom:  return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }
}

/// A rounded-square provider badge (glass tile + brand-tinted glyph), the way
/// the macOS Courier client marks each account.
struct ProviderBadge: View {
    let provider: MailProvider
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(provider.tint.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(provider.tint.opacity(0.45), lineWidth: 1))
            .overlay(
                Image(systemName: provider.icon)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(provider.tint))
            .frame(width: size, height: size)
    }
}
