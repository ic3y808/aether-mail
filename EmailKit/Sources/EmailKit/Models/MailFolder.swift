import Foundation

/// An IMAP mailbox/folder.
public struct MailFolder: Codable, Sendable, Identifiable, Hashable {
    /// Full IMAP path, e.g. `INBOX` or `[Gmail]/Sent Mail`.
    public var path: String
    /// The path separator advertised by LIST (usually `/` or `.`).
    public var separator: String
    /// Special-use role parsed from LIST flags / well-known names.
    public var role: FolderRole
    /// LIST attribute flags we care to remember (\Noselect etc.).
    public var isSelectable: Bool
    public var unreadCount: Int
    public var totalCount: Int

    public var id: String { path }

    public init(
        path: String,
        separator: String = "/",
        role: FolderRole = .other,
        isSelectable: Bool = true,
        unreadCount: Int = 0,
        totalCount: Int = 0
    ) {
        self.path = path
        self.separator = separator
        self.role = role
        self.isSelectable = isSelectable
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }

    /// The leaf display name (last path component).
    public var displayName: String {
        guard let last = path.components(separatedBy: separator).last, !last.isEmpty else {
            return path
        }
        return last
    }
}

/// RFC 6154 special-use roles plus INBOX, so the UI can show canonical icons
/// and order folders sensibly across providers that name them differently.
public enum FolderRole: String, Codable, Sendable {
    case inbox
    case sent
    case drafts
    case trash
    case junk
    case archive
    case all
    case flagged
    case other

    /// Infer a role from an IMAP LIST special-use flag (e.g. `\Sent`).
    public static func from(specialUse flag: String) -> FolderRole? {
        switch flag.lowercased() {
        case "\\sent":    return .sent
        case "\\drafts":  return .drafts
        case "\\trash":   return .trash
        case "\\junk":    return .junk
        case "\\archive": return .archive
        case "\\all":     return .all
        case "\\flagged": return .flagged
        default:          return nil
        }
    }

    /// Fallback inference from a folder's name when no special-use flag exists
    /// (iCloud and some servers omit them).
    public static func from(name: String) -> FolderRole {
        let n = name.lowercased()
        if n == "inbox" { return .inbox }
        if n.contains("sent") { return .sent }
        if n.contains("draft") { return .drafts }
        if n.contains("trash") || n.contains("deleted") { return .trash }
        if n.contains("junk") || n.contains("spam") { return .junk }
        if n.contains("archive") { return .archive }
        if n == "all mail" || n.contains("all mail") { return .all }
        return .other
    }

    /// Sort priority for the folder list (lower = higher).
    public var sortPriority: Int {
        switch self {
        case .inbox:   return 0
        case .flagged: return 1
        case .drafts:  return 2
        case .sent:    return 3
        case .archive: return 4
        case .junk:    return 5
        case .trash:   return 6
        case .all:     return 7
        case .other:   return 8
        }
    }
}

// MARK: - Finding the folder that plays a role

extension MailFolder {

    /// The folder that plays `role` among `folders`, or nil if the server has
    /// none.
    ///
    /// Returns only a folder the server actually reported. Callers used to fall
    /// back to a conventional name when the list was empty, which sent
    /// `UID MOVE ... "Trash"` to servers whose trash is called something else -
    /// `Deleted Messages` on iCloud, `[Gmail]/Trash` on Gmail - and every server
    /// answered NO. A wrong folder is not a better answer than no folder.
    public static func resolve(_ role: FolderRole, in folders: [MailFolder]) -> MailFolder? {
        guard !folders.isEmpty else { return nil }

        if let exact = folders.first(where: { $0.role == role }) { return exact }

        // Gmail has no Archive. Archiving there removes the inbox label and what
        // remains is All Mail, so a request to archive resolves onto it. Without
        // this, Archive is permanently "no such folder" on the most widely used
        // provider there is.
        if role == .archive, let all = folders.first(where: { $0.role == .all }) {
            return all
        }

        // Name fallback, for servers advertising no special-use flags. Matches
        // the LAST path component: these are leaf names, and real paths are
        // namespaced ("[Gmail]/Trash", "INBOX.Trash").
        let names: [FolderRole: [String]] = [
            .trash:   ["Trash", "Deleted Messages", "Deleted Items", "Bin"],
            .archive: ["Archive", "Archives", "All Mail"],
            .junk:    ["Junk", "Spam", "Junk E-mail", "Bulk Mail"],
            .sent:    ["Sent", "Sent Messages", "Sent Items"],
            .drafts:  ["Drafts", "Draft"]
        ]
        guard let candidates = names[role] else { return nil }
        return folders.first { folder in
            candidates.contains { $0.caseInsensitiveCompare(folder.leafName) == .orderedSame }
        }
    }

    /// Last component of the IMAP path — `Trash` for `[Gmail]/Trash`.
    public var leafName: String {
        path.components(separatedBy: CharacterSet(charactersIn: "/.")).last ?? path
    }
}
