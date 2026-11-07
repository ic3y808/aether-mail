import Foundation
import EmailKit

/// Draft state for composing a new message, replying, or forwarding.
struct ComposeDraft: Identifiable, Equatable {
    enum Mode: String, Equatable {
        case compose = "New Message"
        case reply = "Reply"
        case replyAll = "Reply All"
        case forward = "Forward"
    }

    let id = UUID()
    var mode: Mode
    var accountID: UUID
    var to: String
    var cc: String = ""
    var bcc: String = ""
    var subject: String
    var body: String = ""
    var quotedText: String = ""
    var inReplyTo: String? = nil
    var references: [String] = []
    var originalMessage: MailMessage? = nil
}

/// Message actions: read/unread, flag, archive, junk, move, delete, compose and reply.
///
/// The app shipped as a reader — EmailKit could already `store` flags, `move`
/// and `expunge`, but nothing in the UI reached any of it, and marking a message
/// read only ever touched a local `readIDs` set that the server never heard
/// about. This is the write half, matched to the macOS client's semantics so the
/// two behave the same way on the same mailbox.
@MainActor
extension MailStore {

    // MARK: - Where a message lives

    func folderRole(for m: MailMessage) -> FolderRole {
        // Prefer the server's own advertised role; fall back to the path when an
        // account hasn't had its folder list loaded yet.
        if let account = account(for: m),
           let folder = (foldersByAccount[account.id] ?? []).first(where: { $0.path == m.folderPath }),
           folder.role != .other {
            return folder.role
        }
        let path = m.folderPath.lowercased()
        if path.contains("junk") || path.contains("spam") { return .junk }
        if path.contains("trash") || path.contains("deleted") { return .trash }
        if path.contains("archive") { return .archive }
        if path.contains("sent") { return .sent }
        if path.contains("draft") { return .drafts }
        return .inbox
    }

    func folderDisplayName(for m: MailMessage) -> String {
        switch folderRole(for: m) {
        case .junk: return "Junk"
        case .trash: return "Trash"
        case .archive: return "Archive"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        default: return "Inbox"
        }
    }

    /// The server path for `role` on this account, if it has one.
    ///
    /// Only ever returns a folder the server actually reported. It used to fall
    /// back to a conventional name when the folder list had not loaded, which
    /// meant every action fired `UID MOVE ... "Trash"` at servers whose trash is
    /// called something else - `Deleted Messages` on iCloud, `[Gmail]/Trash` on
    /// Gmail - and every one of them answered NO. Guessing looked like
    /// resilience and was the reason nothing could be filed anywhere.
    func resolveFolder(_ account: MailAccount, role: FolderRole) -> String? {
        let folders = foldersByAccount[account.id] ?? []
        guard !folders.isEmpty else { return nil }

        if let match = folders.first(where: { $0.role == role }) { return match.path }

        // Gmail has no Archive: archiving there means taking a message out of
        // the inbox, and what is left is All Mail. Without this, Archive is
        // permanently "no such folder" on the most common provider there is.
        if role == .archive, let all = folders.first(where: { $0.role == .all }) {
            return all.path
        }

        // Name fallback for servers that advertise no special-use flags. Match
        // the LAST path component, because the names below are leaf names and
        // real paths are namespaced - "[Gmail]/Trash", "INBOX.Trash".
        let names: [FolderRole: [String]] = [
            .trash:   ["Trash", "Deleted Messages", "Deleted Items", "Bin"],
            .archive: ["Archive", "All Mail", "Archives"],
            .junk:    ["Junk", "Spam", "Junk E-mail", "Junk Email", "Junk Mail", "Bulk Mail", "Bulk", "Spam Messages"]
        ]
        if let candidates = names[role], let match = (folders.first { folder in
            let leaf = folder.path
                .components(separatedBy: CharacterSet(charactersIn: "/."))
                .last ?? folder.path
            return candidates.contains { $0.caseInsensitiveCompare(leaf) == .orderedSame }
        }?.path) {
            return match
        }

        // Substring fallback for junk/spam if exact leaf name didn't match
        if role == .junk {
            if let loose = folders.first(where: {
                let leaf = ($0.path.components(separatedBy: CharacterSet(charactersIn: "/.")).last ?? $0.path).lowercased()
                return leaf.contains("junk") || leaf.contains("spam") || leaf.contains("bulk")
            })?.path {
                return loose
            }
        }
        return nil
    }

    /// Guarantees the folder list for `account` is loaded before it is consulted.
    ///
    /// Actions used to depend on the Mailboxes screen having been opened at some
    /// point, because that was the only caller of `loadFolders`. Anyone who went
    /// straight to their inbox and swiped had no folder list at all.
    func ensureFolders(_ account: MailAccount) async {
        guard (foldersByAccount[account.id] ?? []).isEmpty else { return }
        await loadFolders(account, force: true)
    }

    // MARK: - Delete

    enum DeleteIntent { case trash, permanent }

    /// What deleting these should mean right now. Mail already in Trash or Junk
    /// has nowhere left to be filed, so there "delete" has to mean expunge —
    /// otherwise the gesture silently does nothing, which is how the macOS
    /// client used to behave before the same fix landed there.
    func deleteIntent(for messages: [MailMessage]) -> DeleteIntent {
        guard !messages.isEmpty else { return .trash }
        let terminal: Set<FolderRole> = [.trash, .junk]
        return messages.allSatisfy { terminal.contains(folderRole(for: $0)) } ? .permanent : .trash
    }

    /// The single entry point every delete affordance goes through: the swipe,
    /// the long-press menu and the reading-view toolbar.
    func requestDelete(_ messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        switch deleteIntent(for: messages) {
        case .trash:     move(messages, toRole: .trash, label: "Trash")
        case .permanent: pendingDelete = messages
        }
    }

    func confirmPendingDelete() {
        guard let messages = pendingDelete else { return }
        pendingDelete = nil
        deleteForever(messages)
    }

    /// Permanently removes `messages`. The one action here that records no undo
    /// step, because nothing survives it to restore — so it asks first instead.
    func deleteForever(_ messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        undoAction = nil

        // EXPUNGE applies to whichever mailbox is selected, so group per account
        // and folder rather than issuing one call.
        var grouped: [UUID: [String: [MailMessage]]] = [:]
        for m in messages { grouped[m.accountID, default: [:]][m.folderPath, default: []].append(m) }
        for m in messages { removeLocal(m) }
        let ids = messages.map(\.id)
        Task { for id in ids { await MailCache.shared.removeBody(for: id) } }

        for (_, byFolder) in grouped {
            for (path, group) in byFolder {
                guard let account = group.first.flatMap({ account(for: $0) }) else { continue }
                let uids = group.map(\.uid)
                Task { @MainActor in
                    do {
                        let client = try await openIMAP(for: account)
                        _ = try await client.select(path)
                        try await client.expunge(uids: uids)
                        await client.disconnect()
                    } catch {
                        // Still on the server, so it must still be in the list.
                        insertLocal(group)
                        banner = "Couldn't delete — \(friendly(error))"
                    }
                }
            }
        }
        banner = messages.count == 1 ? "Deleted permanently."
                                     : "Deleted \(messages.count) messages permanently."
    }

    func archive(_ messages: [MailMessage]) { move(messages, toRole: .archive, label: "Archive") }
    func markAsJunk(_ messages: [MailMessage]) {
        for m in messages {
            for addr in m.from {
                let clean = Self.cleanAddress(addr.address)
                guard !clean.isEmpty else { continue }
                blockedSenders.insert(clean)
                if let domain = Self.extractDomain(from: clean),
                   !Self.publicWebmailDomains.contains(domain) {
                    blockedSenders.insert("@" + domain)
                }
            }
        }
        persist()
        move(messages, toRole: .junk, label: "Junk")
    }

    /// Files `messages` under `role`, optimistically and reversibly.
    func move(_ messages: [MailMessage], toRole role: FolderRole, label: String) {
        guard !messages.isEmpty else { return }

        Task { @MainActor in
            // Resolving needs the folder list, and loading it needs the network,
            // so the whole resolve happens here rather than before the Task.
            var moved: [(MailMessage, String)] = []
            var complained: Set<UUID> = []

            for m in messages {
                guard let account = account(for: m) else { continue }
                await ensureFolders(account)

                var target = resolveFolder(account, role: role)
                if target == nil && role == .junk {
                    // Auto-create "Junk" mailbox on the server so junking never fails
                    if let client = try? await openIMAP(for: account) {
                        _ = try? await client.createFolder("Junk")
                        await client.disconnect()
                        await loadFolders(account, force: true)
                        target = resolveFolder(account, role: role)
                    }
                }
                guard let target else {
                    if complained.insert(account.id).inserted {
                        banner = "\(account.emailAddress) has no \(label) folder."
                    }
                    continue
                }
                guard target != m.folderPath else {
                    banner = "Already in \(folderDisplayName(for: m))."
                    continue
                }
                moved.append((m, target))
            }
            guard !moved.isEmpty else { return }

            for (m, _) in moved { removeLocal(m) }

            // One connection per mailbox, not per message. Opening a fresh IMAP
            // session - TCP, TLS, LOGIN - for each of twenty selected messages
            // fires twenty simultaneous logins; Gmail allows fifteen and answers
            // the rest with "Too many simultaneous connections", and iCloud
            // throttles harder still.
            var grouped: [UUID: [String: [String: [MailMessage]]]] = [:]
            for (m, target) in moved {
                grouped[m.accountID, default: [:]][m.folderPath, default: [:]][target, default: []].append(m)
            }

            for (accountID, byOrigin) in grouped {
                guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
                for (origin, byTarget) in byOrigin {
                    do {
                        let client = try await openIMAP(for: account)
                        _ = try await client.select(origin)
                        for (target, group) in byTarget {
                            try await client.move(uids: group.map(\.uid), to: target)
                        }
                        await client.disconnect()
                    } catch {
                        let failed = byTarget.values.flatMap { $0 }
                        insertLocal(failed)          // they did NOT move
                        banner = "Couldn't move to \(label) — \(friendly(error))"
                    }
                }
            }

            let summary = moved.count == 1 ? "Moved to \(label)" : "Moved \(moved.count) to \(label)"
            undoAction = UndoAction(summary: summary) { [weak self] in
                guard let self else { return }
                self.undoAction = nil
                for (m, target) in moved { self.moveBack(m, from: target) }
            }
        }
    }

    /// Puts a moved message back. The UID changed when the server moved it, so
    /// the copy has to be found again by its Message-ID rather than by UID.
    private func moveBack(_ m: MailMessage, from target: String) {
        guard let account = account(for: m) else { return }
        guard let messageID = m.messageID else {
            banner = "Can't undo — the server didn't give that message an ID."
            return
        }
        let origin = m.folderPath
        insertLocal([m])
        Task { @MainActor in
            do {
                let client = try await openIMAP(for: account)
                _ = try await client.select(target)
                let uids = try await client.uidSearch("HEADER MESSAGE-ID \"\(messageID)\"")
                guard let uid = uids.first else {
                    await client.disconnect()
                    removeLocal(m)
                    banner = "Couldn't undo — the message wasn't in \(target)."
                    return
                }
                try await client.move(uid: uid, to: origin)
                await client.disconnect()
            } catch {
                removeLocal(m)
                banner = "Couldn't undo — \(friendly(error))"
            }
        }
    }

    /// Moves to an explicit folder the user picked.
    func move(_ m: MailMessage, toPath path: String) {
        guard let account = account(for: m), path != m.folderPath else { return }
        let origin = m.folderPath
        removeLocal(m)
        let label = (foldersByAccount[account.id] ?? [])
            .first { $0.path == path }?.displayName ?? path
        Task { @MainActor in
            do {
                let client = try await openIMAP(for: account)
                _ = try await client.select(origin)
                try await client.move(uid: m.uid, to: path)
                await client.disconnect()
            } catch {
                insertLocal([m])
                banner = "Couldn't move to \(label) — \(friendly(error))"
            }
        }
        undoAction = UndoAction(summary: "Moved to \(label)") { [weak self] in
            self?.undoAction = nil
            self?.moveBack(m, from: path)
        }
    }

    /// Folders this message could be filed into — everything on its account bar
    /// where it already is, and bar the folders you don't file *into*.
    func moveDestinations(for m: MailMessage) -> [MailFolder] {
        guard let account = account(for: m) else { return [] }
        let excluded: Set<FolderRole> = [.sent, .drafts, .all, .flagged]
        return (foldersByAccount[account.id] ?? [])
            .filter { $0.path != m.folderPath && !excluded.contains($0.role) }
    }

    // MARK: - Flags

    /// Marks read/unread on the server as well as locally. `readIDs` alone meant
    /// a message re-appeared unread on every other device, and after every sync.
    func setRead(_ m: MailMessage, _ read: Bool) {
        guard let account = account(for: m) else { return }
        if read { readIDs.insert(m.id) } else { readIDs.remove(m.id) }
        mutateLocal(m) { $0.flags = read ? $0.flags.union(.seen) : $0.flags.subtracting(.seen) }
        pendingFlagWrites.insert(m.id)
        Task { @MainActor in
            defer { pendingFlagWrites.remove(m.id) }
            do {
                let client = try await openIMAP(for: account)
                _ = try await client.select(m.folderPath)
                try await client.store(uid: m.uid, flag: "\\Seen", add: read)
                await client.disconnect()
            } catch {
                if read { readIDs.remove(m.id) } else { readIDs.insert(m.id) }
                mutateLocal(m) { $0.flags = read ? $0.flags.subtracting(.seen) : $0.flags.union(.seen) }
                banner = "Couldn't update — \(friendly(error))"
            }
        }
    }

    func setFlagged(_ m: MailMessage, _ flagged: Bool) {
        guard let account = account(for: m) else { return }
        mutateLocal(m) { $0.flags = flagged ? $0.flags.union(.flagged) : $0.flags.subtracting(.flagged) }
        Task { @MainActor in
            do {
                let client = try await openIMAP(for: account)
                _ = try await client.select(m.folderPath)
                try await client.store(uid: m.uid, flag: "\\Flagged", add: flagged)
                await client.disconnect()
            } catch {
                mutateLocal(m) { $0.flags = flagged ? $0.flags.subtracting(.flagged) : $0.flags.union(.flagged) }
                banner = "Couldn't update — \(friendly(error))"
            }
        }
    }

    func toggleFlagged(_ m: MailMessage) { setFlagged(m, !m.flags.contains(.flagged)) }

    // MARK: - Local list bookkeeping

    /// Applies `transform` wherever this message is currently held.
    func mutateLocal(_ m: MailMessage, _ transform: (inout MailMessage) -> Void) {
        defer {
            saveMessageCache()
            updateIconBadge()
        }
        if let idx = messagesByAccount[m.accountID]?.firstIndex(where: { $0.id == m.id }) {
            transform(&messagesByAccount[m.accountID]![idx])
        }
        let key = folderKey(m.accountID, m.folderPath)
        if let idx = messagesByFolder[key]?.firstIndex(where: { $0.id == m.id }) {
            transform(&messagesByFolder[key]![idx])
        }
    }

    func removeLocal(_ m: MailMessage) {
        defer {
            saveMessageCache()
            updateIconBadge()
        }
        messagesByAccount[m.accountID]?.removeAll { $0.id == m.id }
        messagesByFolder[folderKey(m.accountID, m.folderPath)]?.removeAll { $0.id == m.id }
        openBodies[m.id] = nil
    }

    func insertLocal(_ messages: [MailMessage]) {
        defer {
            saveMessageCache()
            updateIconBadge()
        }
        for m in messages {
            if m.folderPath == "INBOX" {
                var list = messagesByAccount[m.accountID] ?? []
                if !list.contains(where: { $0.id == m.id }) { list.append(m) }
                messagesByAccount[m.accountID] = list
            }
            let key = folderKey(m.accountID, m.folderPath)
            var list = messagesByFolder[key] ?? []
            if !list.contains(where: { $0.id == m.id }) { list.append(m) }
            messagesByFolder[key] = list
        }
    }

    // MARK: - Compose / Reply / Forward / Send

    func beginCompose(to: String = "", subject: String = "", body: String = "", accountID: UUID? = nil) {
        guard let accID = accountID ?? enabledAccounts.first?.id ?? accounts.first?.id else {
            banner = "Add a mail account first to send messages."
            return
        }
        activeDraft = ComposeDraft(
            mode: .compose,
            accountID: accID,
            to: to,
            subject: subject,
            body: body
        )
    }

    func reply(to message: MailMessage, all: Bool = false, initialBody: String = "") {
        guard let account = account(for: message) ?? enabledAccounts.first ?? accounts.first else {
            banner = "No mail account available to reply from."
            return
        }
        var toList = message.from.map(\.address)
            .filter { $0.caseInsensitiveCompare(account.emailAddress) != .orderedSame }
        if toList.isEmpty {
            toList = message.to.map(\.address)
            if toList.isEmpty {
                toList = message.from.map(\.address)
            }
        }
        var ccList: [String] = []
        if all {
            toList += message.to.map(\.address)
                .filter { $0.caseInsensitiveCompare(account.emailAddress) != .orderedSame }
            ccList = message.cc.map(\.address)
                .filter { $0.caseInsensitiveCompare(account.emailAddress) != .orderedSame }
        }
        let rawSubject = message.subject.isEmpty ? "(no subject)" : message.subject
        let subject = rawSubject.lowercased().hasPrefix("re:") ? rawSubject : "Re: \(rawSubject)"

        activeDraft = ComposeDraft(
            mode: all ? .replyAll : .reply,
            accountID: account.id,
            to: Self.dedupeAddresses(toList).joined(separator: ", "),
            cc: Self.dedupeAddresses(ccList).joined(separator: ", "),
            subject: subject,
            body: initialBody,
            quotedText: quotedReply(for: message),
            inReplyTo: message.messageID,
            references: message.messageID.map { [$0] } ?? [],
            originalMessage: message
        )

        if openBodies[message.id] == nil {
            Task { @MainActor in
                await loadBody(message)
                if var current = activeDraft, current.originalMessage?.id == message.id {
                    current.quotedText = quotedReply(for: message)
                    activeDraft = current
                }
            }
        }
    }

    func forward(_ message: MailMessage) {
        guard let account = account(for: message) ?? enabledAccounts.first ?? accounts.first else {
            banner = "No mail account available to forward from."
            return
        }
        let rawSubject = message.subject.isEmpty ? "(no subject)" : message.subject
        let subject = rawSubject.lowercased().hasPrefix("fwd:") ? rawSubject : "Fwd: \(rawSubject)"
        let header = "---------- Forwarded message ----------\n"
        activeDraft = ComposeDraft(
            mode: .forward,
            accountID: account.id,
            to: "",
            subject: subject,
            body: "",
            quotedText: header + quotedReply(for: message),
            originalMessage: message
        )

        if openBodies[message.id] == nil {
            Task { @MainActor in
                await loadBody(message)
                if var current = activeDraft, current.originalMessage?.id == message.id {
                    current.quotedText = header + quotedReply(for: message)
                    activeDraft = current
                }
            }
        }
    }

    /// Handles a `mailto:` link tapped inside an email body or passed via URL scheme.
    func handleMailto(_ url: URL, contextMessage: MailMessage? = nil) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let toAddress = components.path.removingPercentEncoding ?? components.path
        var subject = ""
        var cc = ""
        var bcc = ""
        var body = ""
        for item in components.queryItems ?? [] {
            let val = item.value ?? ""
            switch item.name.lowercased() {
            case "subject": subject = val
            case "cc":      cc = val
            case "bcc":     bcc = val
            case "body":    body = val
            case "to" where toAddress.isEmpty:
                break
            default: break
            }
        }
        let accID = contextMessage.flatMap { account(for: $0)?.id }
            ?? enabledAccounts.first?.id
            ?? accounts.first?.id
        guard let accID else {
            banner = "Add a mail account first to send messages."
            return
        }
        if subject.isEmpty, let ctx = contextMessage, !ctx.subject.isEmpty {
            subject = ctx.subject.lowercased().hasPrefix("re:") ? ctx.subject : "Re: \(ctx.subject)"
        }
        activeDraft = ComposeDraft(
            mode: contextMessage != nil ? .reply : .compose,
            accountID: accID,
            to: toAddress,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            quotedText: contextMessage.map { quotedReply(for: $0) } ?? "",
            inReplyTo: contextMessage?.messageID,
            references: contextMessage?.messageID.map { [$0] } ?? [],
            originalMessage: contextMessage
        )
    }

    func quotedReply(for message: MailMessage) -> String {
        let who = message.from.first?.shortLabel ?? "someone"
        let when = message.date?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let text = body(for: message)?.bestText ?? message.snippet
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        if when.isEmpty {
            return "\(who) wrote:\n\(quoted)"
        }
        return "On \(when), \(who) wrote:\n\(quoted)"
    }

    private static func dedupeAddresses(_ addrs: [String]) -> [String] {
        var seen = Set<String>()
        return addrs.filter { addr in
            let clean = cleanAddress(addr)
            return !clean.isEmpty && seen.insert(clean).inserted
        }
    }

    /// Generates an AI-drafted reply for `message` using LAN inference if selected,
    /// falling back to on-device Apple FoundationModels.
    func draftAIReply(for message: MailMessage) async -> String? {
        if openBodies[message.id] == nil {
            await loadBody(message)
        }
        let bodyText = body(for: message)?.bestText ?? message.snippet
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let systemInstruction = """
        Write ONLY the body of a reply to this email, in the first person, as the \
        recipient. Two or three sentences, and it must read as a complete message.

        Rules:
        - Use ONLY facts stated in the email itself. Never invent a number, date, \
          price, quantity or commitment.
        - If it asks something only the recipient could know, write a full sentence \
          around a square-bracket blank, for example "The tolerance we need is [tolerance]."
        - No preamble such as "Here is a draft". No quotation marks around the reply.
        - Output the reply text and nothing else.
        """

        if LabInference.shared.selected != nil {
            let userPrompt = "From: \(message.from.first?.shortLabel ?? "unknown")\nSubject: \(message.subject)\n\n\(String(bodyText.prefix(4000)))"
            if let written = await LabInference.shared.complete(system: systemInstruction, user: userPrompt) {
                return DraftQueue.stripPreamble(written)
            }
        }
        if MailAI.isAvailable {
            if let written = await MailAI.ask(
                systemInstruction,
                subject: message.subject,
                from: message.from.first?.shortLabel ?? "unknown",
                body: bodyText
            ) {
                return DraftQueue.stripPreamble(written)
            }
        }
        return nil
    }

    /// Sends an `OutgoingMessage` via `account`'s SMTP server and marks `replyingTo`
    /// as `\Answered` when applicable. Returns `nil` on success or a friendly error.
    func send(_ message: OutgoingMessage, from account: MailAccount, replyingTo: MailMessage? = nil) async -> String? {
        if demoMode || account.credentialRef == "demo" {
            if let orig = replyingTo {
                mutateLocal(orig) { $0.flags.insert(.answered) }
            }
            activeDraft = nil
            banner = "Message sent."
            return nil
        }

        do {
            let client = try await openSMTP(for: account)
            let raw = MIMEBuilder.build(message)
            try await client.send(
                from: account.emailAddress,
                recipients: message.envelopeRecipients,
                rawMessage: raw
            )
            await client.quit()
        } catch {
            return "Couldn't send — \(friendly(error))"
        }

        if let orig = replyingTo, let origAccount = self.account(for: orig) {
            mutateLocal(orig) { $0.flags.insert(.answered) }
            Task { @MainActor in
                if let imap = try? await openIMAP(for: origAccount) {
                    _ = try? await imap.select(orig.folderPath)
                    try? await imap.store(uid: orig.uid, flag: "\\Answered", add: true)
                    await imap.disconnect()
                }
            }
        }

        activeDraft = nil
        banner = "Message sent."
        return nil
    }
}
