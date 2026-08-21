import Foundation
import EmailKit

/// Message actions: read/unread, flag, archive, junk, move and delete.
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
            .junk:    ["Junk", "Spam", "Junk E-mail", "Bulk Mail"]
        ]
        guard let candidates = names[role] else { return nil }
        return folders.first { folder in
            let leaf = folder.path
                .components(separatedBy: CharacterSet(charactersIn: "/."))
                .last ?? folder.path
            return candidates.contains { $0.caseInsensitiveCompare(leaf) == .orderedSame }
        }?.path
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

    // MARK: - Move

    func archive(_ messages: [MailMessage]) { move(messages, toRole: .archive, label: "Archive") }
    func markAsJunk(_ messages: [MailMessage]) { move(messages, toRole: .junk, label: "Junk") }

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

                guard let target = resolveFolder(account, role: role) else {
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
        Task { @MainActor in
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
        defer { saveMessageCache() }
        if let idx = messagesByAccount[m.accountID]?.firstIndex(where: { $0.id == m.id }) {
            transform(&messagesByAccount[m.accountID]![idx])
        }
        let key = folderKey(m.accountID, m.folderPath)
        if let idx = messagesByFolder[key]?.firstIndex(where: { $0.id == m.id }) {
            transform(&messagesByFolder[key]![idx])
        }
    }

    func removeLocal(_ m: MailMessage) {
        defer { saveMessageCache() }
        messagesByAccount[m.accountID]?.removeAll { $0.id == m.id }
        messagesByFolder[folderKey(m.accountID, m.folderPath)]?.removeAll { $0.id == m.id }
        openBodies[m.id] = nil
    }

    func insertLocal(_ messages: [MailMessage]) {
        defer { saveMessageCache() }
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
}
