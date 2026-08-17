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
    var messagesByAccount: [UUID: [MailMessage]] = [:]
    var openBodies: [String: MailBody] = [:]     // message id → parsed body (observed)
    var readIDs: Set<String> = []                // locally-marked-read this session

    var isAddingAccount = false
    var isSyncing = false
    var banner: String?

    private static let accountsKey = "com.aether.mail.accounts.v1"

    init() {
        load()
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
        try await client.login(user: email, password: password.filter { !$0.isWhitespace && $0 != "-" })
        return client
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

        do {
            let client = try await openIMAP(imap, email: email, password: password)
            _ = try await client.select("INBOX")
            await client.disconnect()
        } catch {
            return friendly(error)
        }

        let ref = "mail-\(email)-\(UUID().uuidString)"
        Keychain.set(password.filter { !$0.isWhitespace && $0 != "-" }, for: ref)
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
        persist()
    }

    // MARK: - Sync

    func sync(_ account: MailAccount) async {
        do {
            let client = try await openIMAP(for: account)
            _ = try await client.select("INBOX")
            let uids = try await client.uidSearch("ALL")
            let recent = Array(uids.suffix(60))            // newest 60
            if recent.isEmpty { messagesByAccount[account.id] = []; await client.disconnect(); return }
            let set = recent.map(String.init).joined(separator: ",")
            let fetched = try await client.fetchSummaries(uidSet: set)
            await client.disconnect()
            messagesByAccount[account.id] = fetched.map { m in
                var m = m; m.accountID = account.id; m.folderPath = "INBOX"; return m
            }
        } catch {
            banner = "Couldn't sync \(account.emailAddress) — \(friendly(error))"
        }
    }

    func refresh() {
        Task {
            isSyncing = true
            for a in enabledAccounts { await sync(a) }
            isSyncing = false
        }
    }

    // MARK: - Reading

    func open(_ m: MailMessage) {
        readIDs.insert(m.id)                                // local mark-read
        Task { await loadBody(m) }
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
