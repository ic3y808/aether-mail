import Foundation
import Observation
import EmailKit

/// Real multi-account state for Aether Mail. Accounts persist to UserDefaults;
/// their passwords live in the Keychain. Mail flows over the shared EmailKit
/// engine (IMAP over Network.framework) — the exact same code the macOS client
/// uses. AI routing (on-device → Mac → cloud) layers in after this.
@MainActor @Observable
final class MailStore {
    private(set) var accounts: [MailAccount] = []
    var messagesByAccount: [UUID: [MailMessage]] = [:]   // INBOX per account (All Inboxes)
    var messagesByFolder: [String: [MailMessage]] = [:]  // any folder, key = accountID⋯path
    var foldersByAccount: [UUID: [MailFolder]] = [:]     // IMAP folder list per account
    var openBodies: [String: MailBody] = [:]     // message id → parsed body (observed)
    var summaries: [String: String] = [:]        // message id → on-device AI summary
    var readIDs: Set<String> = []                // locally-marked-read this session
    var syncState: [UUID: SyncState] = [:]       // per-account sync status (shown in UI)
    @ObservationIgnored private var summarizing: Set<String> = []

    enum SyncState: Equatable {
        case idle, syncing, ok
        case failed(String)
        var errorText: String? { if case .failed(let s) = self { return s } else { return nil } }
    }

    var isAddingAccount = false
    var isSyncing = false
    var banner: String?

    private static let accountsKey = "com.aether.mail.accounts.v1"

    init() {
        load()
        WatchBridge.shared.activate()             // start the paired-watch link
        isAddingAccount = accounts.isEmpty        // onboarding when there are none
        if !accounts.isEmpty { refresh() }
    }

    // MARK: - Derived

    var enabledAccounts: [MailAccount] { accounts.filter(\.isEnabled).sorted { $0.sortIndex < $1.sortIndex } }

    var inbox: [MailMessage] {
        enabledAccounts.flatMap { messagesByAccount[$0.id] ?? [] }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    var unreadCount: Int { inbox.filter { isUnread($0) }.count }
    var hasSyncErrors: Bool { enabledAccounts.contains { syncState[$0.id]?.errorText != nil } }

    func account(for m: MailMessage) -> MailAccount? { accounts.first { $0.id == m.accountID } }
    func isUnread(_ m: MailMessage) -> Bool { m.isUnread && !readIDs.contains(m.id) }
    func body(for m: MailMessage) -> MailBody? { openBodies[m.id] }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsKey),
              let saved = try? JSONDecoder().decode([MailAccount].self, from: data) else { return }
        accounts = saved
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    // MARK: - Connection (shared recipe)

    private func makeTransport(_ ep: ServerEndpoint) -> MailTransport {
        ep.security == .startTLS ? STARTTLSTransport(endpoint: ep) : NWConnectionTransport(endpoint: ep)
    }

    private func openIMAP(_ imap: ServerEndpoint, email: String, password: String) async throws -> IMAPClient {
        let client = IMAPClient(transport: makeTransport(imap))
        try await client.connect()
        if imap.security == .startTLS { try await client.startTLS() }
        try await client.login(user: email, password: password)   // caller has normalized it
        return client
    }

    /// Apple shows app-specific passwords as `xxxx-xxxx-xxxx-xxxx`, but iCloud
    /// wants the 16 characters WITHOUT the dashes. Other providers may have real
    /// dashes in the password, so only strip them for iCloud.
    private func normalizedPassword(_ password: String, _ provider: MailProvider) -> String {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider == .icloud ? trimmed.filter { $0 != "-" && !$0.isWhitespace } : trimmed
    }

    /// Connect + authenticate for a saved account — password OR OAuth (XOAUTH2).
    private func openIMAP(for account: MailAccount) async throws -> IMAPClient {
        let client = IMAPClient(transport: makeTransport(account.imap))
        try await client.connect()
        if account.imap.security == .startTLS { try await client.startTLS() }
        if account.provider.authKind == .oauth {
            let token = try await validAccessToken(for: account)
            try await client.authenticateXOAUTH2(user: account.emailAddress, accessToken: token)
        } else if let pw = Keychain.getString(account.credentialRef) {
            try await client.login(user: account.emailAddress, password: pw)
        } else {
            throw NSError(domain: "AetherMail", code: 1, userInfo: [NSLocalizedDescriptionKey: "No saved credentials."])
        }
        return client
    }

    // OAuth tokens live as JSON in the Keychain under the account's credentialRef.
    private func storeTokens(_ tokens: OAuthTokens, ref: String) {
        if let data = try? JSONEncoder().encode(tokens), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: ref)
        }
    }
    private func loadTokens(_ ref: String) -> OAuthTokens? {
        guard let s = Keychain.getString(ref), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }
    private func validAccessToken(for account: MailAccount) async throws -> String {
        guard var tokens = loadTokens(account.credentialRef) else {
            throw NSError(domain: "AetherMail", code: 2, userInfo: [NSLocalizedDescriptionKey: "Please sign in again."])
        }
        if tokens.isExpired, let refresh = tokens.refreshToken, let config = OAuthClients.config(for: account.provider) {
            tokens = try await OAuthAuthenticator().refresh(config: config, refreshToken: refresh)
            storeTokens(tokens, ref: account.credentialRef)
        }
        return tokens.accessToken
    }

    /// "Sign in with Google / Microsoft": runs the OAuth flow, validates over
    /// XOAUTH2, then saves. `email` is the mailbox this account is for.
    func addOAuthAccount(provider: MailProvider, email rawEmail: String) async -> String? {
        let email = normalizeEmail(rawEmail, provider)
        guard email.contains("@") else { return "Enter your email address first." }
        guard let config = OAuthClients.config(for: provider) else {
            return "\(provider.displayName) sign-in isn't configured in this build."
        }
        let tokens: OAuthTokens
        do {
            tokens = try await OAuthAuthenticator().signIn(config: config)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let imap = ProviderCatalog.imap(for: provider)
        do {
            let client = IMAPClient(transport: makeTransport(imap))
            try await client.connect()
            try await client.authenticateXOAUTH2(user: email, accessToken: tokens.accessToken)
            _ = try await client.select("INBOX")
            await client.disconnect()
        } catch {
            return "Signed in, but couldn't reach the mailbox — \(friendly(error))"
        }
        let ref = "oauth-\(email)-\(UUID().uuidString)"
        storeTokens(tokens, ref: ref)
        let account = MailAccount(provider: provider, emailAddress: email, displayName: email,
                                  imap: imap, smtp: ProviderCatalog.smtp(for: provider),
                                  credentialRef: ref, sortIndex: accounts.count)
        accounts.append(account)
        persist()
        await sync(account)
        return nil
    }

    // MARK: - Add / remove account

    /// Validates + saves an account, then syncs it. Returns an error string on
    /// failure, or nil on success.
    func addAccount(provider: MailProvider, email rawEmail: String, password: String, customHost: String) async -> String? {
        let email = normalizeEmail(rawEmail, provider)
        guard email.contains("@") else { return "Enter a valid email address." }

        let imap: ServerEndpoint
        if provider == .custom {
            let host = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return "Enter your IMAP server host (e.g. imap.example.com)." }
            imap = ServerEndpoint(host: host, port: 993, security: .implicitTLS)
        } else {
            imap = ProviderCatalog.imap(for: provider)
        }

        let pw = normalizedPassword(password, provider)
        do {
            let client = try await openIMAP(imap, email: email, password: pw)
            _ = try await client.select("INBOX")
            await client.disconnect()
        } catch {
            return friendly(error)
        }

        let ref = "mail-\(email)-\(UUID().uuidString)"
        Keychain.set(pw, for: ref)
        let smtp = provider == .custom
            ? ServerEndpoint(host: imap.host.replacingOccurrences(of: "imap", with: "smtp"), port: 587, security: .startTLS)
            : ProviderCatalog.smtp(for: provider)
        let account = MailAccount(provider: provider, emailAddress: email, displayName: email,
                                  imap: imap, smtp: smtp, credentialRef: ref, sortIndex: accounts.count)
        accounts.append(account)
        persist()
        await sync(account)
        return nil
    }

    func removeAccount(_ account: MailAccount) {
        Keychain.delete(account.credentialRef)
        accounts.removeAll { $0.id == account.id }
        messagesByAccount[account.id] = nil
        foldersByAccount[account.id] = nil
        syncState[account.id] = nil
        messagesByFolder = messagesByFolder.filter { !$0.key.hasPrefix(account.id.uuidString) }
        persist()
    }

    // MARK: - Sync

    func sync(_ account: MailAccount) async {
        syncState[account.id] = .syncing
        do {
            let client = try await openIMAP(for: account)
            _ = try await client.select("INBOX")
            let uids = try await client.uidSearch("ALL")
            let recent = Array(uids.suffix(60))            // newest 60
            if recent.isEmpty {
                messagesByAccount[account.id] = []
                await client.disconnect()
                syncState[account.id] = .ok
                return
            }
            let set = recent.map(String.init).joined(separator: ",")
            let fetched = try await client.fetchSummaries(uidSet: set)
            await client.disconnect()
            messagesByAccount[account.id] = fetched.map { m in
                var m = m; m.accountID = account.id; m.folderPath = "INBOX"; return m
            }
            syncState[account.id] = .ok
        } catch {
            syncState[account.id] = .failed(friendly(error))
            banner = "Couldn't sync \(account.emailAddress) — \(friendly(error))"
        }
    }

    // MARK: - Folders

    /// Stable key for a (account, folder-path) pair.
    func folderKey(_ account: UUID, _ path: String) -> String { "\(account.uuidString)\u{1}\(path)" }

    /// Messages currently loaded for a specific folder, newest first.
    func messages(_ account: UUID, _ path: String) -> [MailMessage] {
        (messagesByFolder[folderKey(account, path)] ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Load the IMAP folder list for an account (used by the Mailboxes screen).
    func loadFolders(_ account: MailAccount) async {
        guard foldersByAccount[account.id] == nil else { return }
        do {
            let client = try await openIMAP(for: account)
            let folders = try await client.listFolders()
            await client.disconnect()
            foldersByAccount[account.id] = folders
                .filter(\.isSelectable)
                .sorted { $0.role.sortRank != $1.role.sortRank
                    ? $0.role.sortRank < $1.role.sortRank
                    : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            banner = "Couldn't list folders for \(account.emailAddress) — \(friendly(error))"
        }
    }

    /// Sync the newest messages of an arbitrary folder into `messagesByFolder`.
    func syncFolder(_ account: MailAccount, _ path: String) async {
        do {
            let client = try await openIMAP(for: account)
            _ = try await client.select(path)
            let uids = try await client.uidSearch("ALL")
            let recent = Array(uids.suffix(60))
            let key = folderKey(account.id, path)
            if recent.isEmpty { messagesByFolder[key] = []; await client.disconnect(); return }
            let set = recent.map(String.init).joined(separator: ",")
            let fetched = try await client.fetchSummaries(uidSet: set)
            await client.disconnect()
            messagesByFolder[key] = fetched.map { m in
                var m = m; m.accountID = account.id; m.folderPath = path; return m
            }
        } catch {
            banner = "Couldn't open \(path) — \(friendly(error))"
        }
    }

    func refresh() {
        Task {
            isSyncing = true
            for a in enabledAccounts { await sync(a) }
            isSyncing = false
            WatchBridge.shared.sync(from: self)   // mirror the fresh inbox to the watch
            prefetchInbox()                        // warm bodies + AI summaries in the background
        }
    }

    // MARK: - Background prefetch

    /// How many of the newest messages per account to pre-load (body + summary)
    /// so opening them is instant rather than showing a spinner.
    private static let prefetchCount = 12
    @ObservationIgnored private var prefetching = false

    /// After a sync, quietly download the newest message bodies and compute their
    /// on-device summaries, so by the time the user taps in it's already there.
    /// Runs at low priority, one message at a time, and skips anything already
    /// cached — safe to call after every refresh.
    func prefetchInbox() {
        guard !prefetching else { return }
        prefetching = true
        Task(priority: .utility) {
            defer { prefetching = false }
            for account in enabledAccounts {
                let newest = (messagesByAccount[account.id] ?? [])
                    .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                    .prefix(Self.prefetchCount)
                let needBody = newest.filter { openBodies[$0.id] == nil }
                if !needBody.isEmpty {                       // one connection for the whole batch
                    if let client = try? await openIMAP(for: account),
                       (try? await client.select("INBOX")) != nil {
                        for m in needBody where openBodies[m.id] == nil {
                            if let raw = try? await client.fetchRawMessage(uid: m.uid) {
                                openBodies[m.id] = MIMEMessageParser.parse(raw)
                            }
                        }
                        await client.disconnect()
                    }
                }
                for m in newest where summaries[m.id] == nil {   // on-device AI, paced
                    await summarizeIfNeeded(m)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    // MARK: - Reading

    var aiAvailable: Bool { MailAI.isAvailable }
    func summary(for id: String) -> String? { summaries[id] }

    func open(_ m: MailMessage) {
        readIDs.insert(m.id)                                // local mark-read
        WatchBridge.shared.sync(from: self)                 // unread count changed
        Task {
            await loadBody(m)
            await summarizeIfNeeded(m)                       // on-device AI summary
        }
        if m.isUnread, let account = account(for: m) {
            Task {                                          // best-effort \Seen on the server
                if let client = try? await openIMAP(for: account) {
                    _ = try? await client.select(m.folderPath)
                    try? await client.store(uid: m.uid, flag: "\\Seen", add: true)
                    await client.disconnect()
                }
            }
        }
    }

    private func loadBody(_ m: MailMessage) async {
        guard openBodies[m.id] == nil, let account = account(for: m) else { return }
        do {
            let client = try await openIMAP(for: account)
            _ = try await client.select(m.folderPath)
            let raw = try await client.fetchRawMessage(uid: m.uid)
            await client.disconnect()
            openBodies[m.id] = MIMEMessageParser.parse(raw)
        } catch {
            openBodies[m.id] = MailBody(plainText: "Couldn't load this message.\n\n\(friendly(error))")
        }
    }

    private func summarizeIfNeeded(_ m: MailMessage) async {
        guard MailAI.isAvailable, summaries[m.id] == nil, !summarizing.contains(m.id) else { return }
        summarizing.insert(m.id)
        defer { summarizing.remove(m.id) }
        let body = openBodies[m.id]?.bestText ?? m.snippet
        if let s = await MailAI.summarize(subject: m.subject,
                                          from: m.from.first?.shortLabel ?? "unknown", body: body) {
            summaries[m.id] = s
            WatchBridge.shared.sync(from: self)   // push the new summary to the watch
        }
    }

    /// Answer a free-form question about an open email, on-device.
    func ask(_ question: String, about m: MailMessage) async -> String? {
        let body = openBodies[m.id]?.bestText ?? m.snippet
        return await MailAI.ask(question, subject: m.subject,
                                from: m.from.first?.shortLabel ?? "unknown", body: body)
    }

    // MARK: - Helpers

    /// Accept a bare user id for providers with a fixed domain (Gmail → @gmail.com,
    /// iCloud → @icloud.com).
    private func normalizeEmail(_ raw: String, _ provider: MailProvider) -> String {
        var e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.contains("@") {
            switch provider {
            case .gmail:  e += "@gmail.com"
            case .icloud: e += "@icloud.com"
            default:      break
            }
        }
        return e
    }

    private func friendly(_ error: Error) -> String {
        let s = "\(error)".lowercased()
        if s.contains("auth") || s.contains("login") || s.contains("credential") {
            return "Sign-in failed — check the email and app-specific password."
        }
        if s.contains("host") || s.contains("connect") || s.contains("timed out") || s.contains("network") {
            return "Couldn't reach the server. Check the host and your connection."
        }
        return error.localizedDescription
    }
}
