import Foundation

/// A lightweight, watch-sized snapshot of one inbox message. The iPhone runs the
/// heavy IMAP + on-device AI; the Watch only ever sees these tiny values, pushed
/// over WatchConnectivity. Kept in a `Shared/` folder compiled into BOTH the iOS
/// app and the watchOS app so the wire format can never drift.
public struct MailGlance: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sender: String
    public var subject: String
    public var snippet: String
    public var summary: String?     // on-device AI one-liner, if computed yet
    public var unread: Bool
    public var date: Date?

    public init(id: String, sender: String, subject: String, snippet: String,
                summary: String?, unread: Bool, date: Date?) {
        self.id = id; self.sender = sender; self.subject = subject
        self.snippet = snippet; self.summary = summary; self.unread = unread; self.date = date
    }
}

/// The whole mirror the phone hands the watch: a header count plus recent items.
public struct MailMirror: Codable, Sendable {
    public var unreadCount: Int
    public var messages: [MailGlance]
    public var updatedAt: Date

    public init(unreadCount: Int, messages: [MailGlance], updatedAt: Date = .now) {
        self.unreadCount = unreadCount; self.messages = messages; self.updatedAt = updatedAt
    }

    /// WatchConnectivity applicationContext is a `[String: Any]`; we ship the
    /// mirror as one JSON blob under this key.
    public static let contextKey = "mirror"

    public func asContext() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.contextKey: data]
    }
    public static func from(context: [String: Any]) -> MailMirror? {
        guard let data = context[contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(MailMirror.self, from: data)
    }
}
