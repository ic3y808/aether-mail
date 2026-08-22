import Foundation
import EmailKit

/// On-disk cache for everything the app would otherwise re-fetch or re-compute
/// on every launch: message summaries per folder, parsed bodies, and the
/// on-device AI summaries.
///
/// Only accounts were ever persisted, so a cold start showed an empty inbox,
/// re-downloaded the newest 60 messages per account, re-fetched every body and
/// re-ran every AI summary — work that had already been done, sometimes minutes
/// earlier. Bodies and summaries are immutable once computed for a given
/// message, which makes them worth keeping indefinitely rather than recomputing.
///
/// An actor, so the file I/O stays off the main thread; `MailStore` is
/// `@MainActor` and would otherwise block the UI writing megabytes of JSON.
actor MailCache {
    static let shared = MailCache()

    /// A folder's cached messages, tagged with the UIDVALIDITY they were fetched
    /// under. IMAP UIDs are only meaningful within one UIDVALIDITY — if the
    /// server changes it, every cached UID is meaningless and the folder has to
    /// be re-fetched from scratch.
    struct FolderCache: Codable {
        var uidValidity: UInt32?
        var messages: [MailMessage]
    }

    /// Bumped when a defect made previously-written cache entries untrustworthy.
    /// On a mismatch the whole cache is discarded rather than migrated - it is
    /// all re-derivable from the server, and there is no way to tell a poisoned
    /// entry from a good one after the fact.
    ///
    /// v2: entries written before this carry summaries generated from failure
    /// text ("... failed to load due to a connection timeout") and bodies that
    /// were empty because a failed FETCH returned zero bytes and was cached as a
    /// success. Both were served forever and never recomputed.
    private static let version = 2

    private let root: URL
    private let bodiesDir: URL

    /// Bodies can carry attachment data, so they are capped both individually and
    /// in total; a 40 MB newsletter is not worth keeping to save one fetch.
    private static let maxBodyBytes = 2 * 1024 * 1024
    private static let maxBodyFiles = 600

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        root = base.appendingPathComponent("AetherMail/Cache", isDirectory: true)
        bodiesDir = root.appendingPathComponent("bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
        Self.discardIfStale(root: root, bodiesDir: bodiesDir)
    }

    /// Wipes the cache when it was written by an older, buggier version.
    private nonisolated static func discardIfStale(root: URL, bodiesDir: URL) {
        let marker = root.appendingPathComponent("version")
        let found = (try? String(contentsOf: marker, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard found != Self.version else { return }

        let fm = FileManager.default
        for name in ["folders.json", "messages.json", "ai.json", "read.json"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        try? fm.removeItem(at: bodiesDir)
        try? fm.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
        try? "\(Self.version)".write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Paths

    private var foldersURL: URL { root.appendingPathComponent("folders.json") }
    private var messagesURL: URL { root.appendingPathComponent("messages.json") }
    private var summariesURL: URL { root.appendingPathComponent("ai.json") }
    private var readURL: URL { root.appendingPathComponent("read.json") }

    /// Message ids contain ':' and account UUIDs; hash them so the filename is
    /// always a valid, fixed-length component.
    private func bodyURL(_ messageID: String) -> URL {
        bodiesDir.appendingPathComponent("\(stableHash(messageID)).json")
    }

    private func stableHash(_ s: String) -> String {
        // FNV-1a. Not cryptographic — this only has to be stable across launches
        // and collision-resistant enough for a local filename.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    // MARK: - Read

    struct Snapshot: Sendable {
        var folders: [UUID: [MailFolder]] = [:]
        var byFolder: [String: FolderCache] = [:]
        var summaries: [String: String] = [:]
        var readIDs: Set<String> = []
    }

    func loadSnapshot() -> Snapshot {
        var snap = Snapshot()
        if let raw: [String: [MailFolder]] = decode(foldersURL) {
            for (key, value) in raw { if let id = UUID(uuidString: key) { snap.folders[id] = value } }
        }
        snap.byFolder = decode(messagesURL) ?? [:]
        snap.summaries = decode(summariesURL) ?? [:]
        snap.readIDs = Set(decode(readURL) as [String]? ?? [])
        return snap
    }

    /// A cached body with no content is treated as a miss, so anything written by
    /// an older build is refetched rather than served forever.
    func body(_ messageID: String) -> MailBody? {
        guard let cached: MailBody = decode(bodyURL(messageID)), cached.hasContent else { return nil }
        return cached
    }

    // MARK: - Write

    func saveFolders(_ folders: [UUID: [MailFolder]]) {
        var keyed: [String: [MailFolder]] = [:]
        for (id, value) in folders { keyed[id.uuidString] = value }
        encode(keyed, to: foldersURL)
    }

    func saveMessages(_ byFolder: [String: FolderCache]) { encode(byFolder, to: messagesURL) }
    func saveSummaries(_ summaries: [String: String]) { encode(summaries, to: summariesURL) }
    func saveReadIDs(_ ids: Set<String>) { encode(Array(ids), to: readURL) }

    func saveBody(_ body: MailBody, for messageID: String) {
        // An empty body means the fetch or the parse failed, not that the email
        // is blank. Caching it made "(no content)" permanent, because a cache hit
        // stops the retry.
        guard body.hasContent else { return }
        guard let data = try? JSONEncoder().encode(body), data.count <= Self.maxBodyBytes else { return }
        try? data.write(to: bodyURL(messageID), options: .atomic)
        pruneBodiesIfNeeded()
    }

    func removeBody(for messageID: String) { try? FileManager.default.removeItem(at: bodyURL(messageID)) }

    /// Drops the least-recently-modified bodies once the directory grows past the
    /// cap, so the cache cannot expand without bound.
    private func pruneBodiesIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: bodiesDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Self.maxBodyFiles else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(files.count - Self.maxBodyFiles) { try? fm.removeItem(at: url) }
    }

    /// Wipes everything for an account that was removed.
    func purge(account: UUID) {
        var byFolder: [String: FolderCache] = decode(messagesURL) ?? [:]
        let prefix = account.uuidString
        for (key, cache) in byFolder where key.hasPrefix(prefix) {
            for m in cache.messages { removeBody(for: m.id) }
            byFolder[key] = nil
        }
        encode(byFolder, to: messagesURL)

        var folders: [String: [MailFolder]] = decode(foldersURL) ?? [:]
        folders[prefix] = nil
        encode(folders, to: foldersURL)

        // Summaries and read ids are keyed by message id, which begins with the
        // account UUID - without this a removed account left its AI summaries and
        // read state on disk indefinitely.
        var summaries: [String: String] = decode(summariesURL) ?? [:]
        summaries = summaries.filter { !$0.key.hasPrefix(prefix) }
        encode(summaries, to: summariesURL)

        let read = (decode(readURL) as [String]? ?? []).filter { !$0.hasPrefix(prefix) }
        encode(read, to: readURL)
    }

    // MARK: - Codable plumbing

    private func decode<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
