import Foundation
import EmailKit

/// Cache restore, incremental sync, and the summary backfill.
@MainActor
extension MailStore {

    // MARK: - Restore

    /// Repopulates the lists, AI summaries and read state from disk before the
    /// first network call, so a launch shows mail immediately instead of an empty
    /// inbox and a spinner.
    func restoreCache() async {
        let snap = await MailCache.shared.loadSnapshot()
        foldersByAccount = snap.folders
        summaries = snap.summaries
        readIDs = snap.readIDs

        for (key, cache) in snap.byFolder {
            uidValidityByFolder[key] = cache.uidValidity
            // INBOX feeds the combined "All Inboxes" list; other folders are
            // keyed by path.
            if let first = cache.messages.first, first.folderPath == "INBOX" {
                messagesByAccount[first.accountID] = cache.messages
            }
            messagesByFolder[key] = cache.messages
        }
        cacheRestored = true
        WatchBridge.shared.sync(from: self)
    }

    // MARK: - Incremental sync

    /// Returns the folder's newest messages, fetching summaries **only** for UIDs
    /// that aren't already cached.
    ///
    /// The whole point of the cache: a refresh that finds two new messages should
    /// fetch two, not sixty. Messages the server no longer lists are dropped, so
    /// mail deleted on another device disappears here too.
    func mergeIncrementally(client: IMAPClient,
                            cached: [MailMessage],
                            key: String,
                            serverValidity: UInt32?,
                            wantedUIDs: [UInt32],
                            accountID: UUID,
                            path: String) async throws -> [MailMessage] {

        let plan = SyncPlan.plan(cachedUIDs: cached.map(\.uid),
                                 cachedValidity: uidValidityByFolder[key],
                                 serverUIDs: wantedUIDs,
                                 serverValidity: serverValidity)
        uidValidityByFolder[key] = serverValidity ?? uidValidityByFolder[key]

        var byUID = Dictionary(uniqueKeysWithValues: cached.map { ($0.uid, $0) })

        // Whatever the plan drops is gone from this folder: either the server no
        // longer lists it, or UIDVALIDITY changed and the UID now means something
        // else entirely. Either way its cached body must not be reused.
        let droppedIDs = Set(plan.dropped)
        for m in cached where droppedIDs.contains(m.uid) {
            await MailCache.shared.removeBody(for: m.id)
            byUID[m.uid] = nil
        }

        if !plan.toFetch.isEmpty {
            let set = plan.toFetch.map(String.init).joined(separator: ",")
            for var m in try await client.fetchSummaries(uidSet: set) {
                m.accountID = accountID
                m.folderPath = path
                byUID[m.uid] = m
            }
        }

        return wantedUIDs.compactMap { byUID[$0] }
    }

    // MARK: - Persist

    /// Writes the message lists out. Debounced — a refresh touches every folder,
    /// and encoding the whole cache once per folder would be pointless work.
    func saveMessageCache() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            var out: [String: MailCache.FolderCache] = [:]
            for (key, messages) in messagesByFolder where !messages.isEmpty {
                out[key] = MailCache.FolderCache(uidValidity: uidValidityByFolder[key], messages: messages)
            }
            for (accountID, messages) in messagesByAccount where !messages.isEmpty {
                let key = folderKey(accountID, "INBOX")
                out[key] = MailCache.FolderCache(uidValidity: uidValidityByFolder[key], messages: messages)
            }
            let folders = foldersByAccount
            let ids = readIDs
            await MailCache.shared.saveMessages(out)
            await MailCache.shared.saveFolders(folders)
            await MailCache.shared.saveReadIDs(ids)
        }
    }

    func saveSummaryCache() {
        summarySaveTask?.cancel()
        summarySaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let snapshot = summaries
            await MailCache.shared.saveSummaries(snapshot)
        }
    }

    // MARK: - Summary backfill

    /// Fills in AI summaries for every cached message that lacks one, so opening
    /// anything — not just the newest handful the prefetch reached — is instant.
    ///
    /// Runs at background priority, one at a time, and yields between messages:
    /// on-device inference competes with the UI for the same silicon, and a
    /// backfill that janks the list is worse than one that takes longer. Resumes
    /// where it left off on the next launch, because the results are on disk.
    func backfillSummaries() {
        guard MailAI.isAvailable, !backfilling else { return }
        backfilling = true
        Task(priority: .background) { @MainActor in
            defer { backfilling = false }

            // Newest first — that is what someone is most likely to open next.
            let pending = (messagesByAccount.values.flatMap { $0 } + messagesByFolder.values.flatMap { $0 })
                .filter { summaries[$0.id] == nil }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

            var seen = Set<String>()
            for m in pending {
                guard !Task.isCancelled else { return }
                guard seen.insert(m.id).inserted else { continue }
                guard summaries[m.id] == nil else { continue }

                // A summary needs the body; fetch it if this one was never opened.
                if openBodies[m.id] == nil { await loadBody(m) }
                await summarizeIfNeeded(m)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}
