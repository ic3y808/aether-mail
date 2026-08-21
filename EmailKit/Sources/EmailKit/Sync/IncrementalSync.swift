import Foundation

/// Works out how much of a folder actually has to be fetched.
///
/// A refresh that finds two new messages should fetch two, not the whole window
/// again. Kept pure and separate from the client so the decision — which is the
/// part that loses mail when it is wrong — can be tested without a server.
public struct SyncPlan: Equatable, Sendable {
    /// UIDs with no usable cache entry; these need FETCHing.
    public var toFetch: [UInt32]
    /// UIDs served from cache.
    public var reused: [UInt32]
    /// Cached UIDs the server no longer lists — gone, or moved elsewhere.
    public var dropped: [UInt32]
    /// True when the cache was discarded wholesale because UIDVALIDITY changed.
    public var invalidated: Bool

    /// - Parameters:
    ///   - cachedUIDs: what the local cache holds for this folder.
    ///   - cachedValidity: the UIDVALIDITY those UIDs were fetched under, if known.
    ///   - serverUIDs: the window the caller wants, in the order it wants it.
    ///   - serverValidity: UIDVALIDITY the server just reported.
    public static func plan(cachedUIDs: [UInt32],
                            cachedValidity: UInt32?,
                            serverUIDs: [UInt32],
                            serverValidity: UInt32?) -> SyncPlan {
        // IMAP UIDs are only unique within one UIDVALIDITY (RFC 3501 §2.3.1.1).
        // If the server changed it, every cached UID refers to a different
        // message than it used to, and reusing any of them would show the wrong
        // mail under the right subject.
        let invalidated: Bool = {
            guard let serverValidity, let cachedValidity else { return false }
            return serverValidity != cachedValidity
        }()

        let usable = invalidated ? [] : cachedUIDs
        let cached = Set(usable)
        let wanted = Set(serverUIDs)

        return SyncPlan(
            toFetch: serverUIDs.filter { !cached.contains($0) },
            reused: serverUIDs.filter { cached.contains($0) },
            // On invalidation every cached entry is stale, so the caller is told
            // to drop all of them - otherwise their cached bodies leak, keyed to
            // UIDs that now mean something else.
            dropped: invalidated ? cachedUIDs : usable.filter { !wanted.contains($0) },
            invalidated: invalidated
        )
    }

    /// Nothing to do: the cache already covers the whole window.
    public var isUpToDate: Bool { toFetch.isEmpty && dropped.isEmpty && !invalidated }
}
