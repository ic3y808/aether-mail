import Testing
@testable import EmailKit

/// The app used to re-fetch the newest 60 messages of every folder on every
/// launch and every refresh, no matter how much of it was already on the device.
/// These pin the decision about what actually has to be fetched.
@Suite("Incremental sync planning")
struct IncrementalSyncTests {

    @Test("A cold cache fetches everything")
    func coldCache() {
        let plan = SyncPlan.plan(cachedUIDs: [], cachedValidity: nil,
                                 serverUIDs: [1, 2, 3], serverValidity: 100)
        #expect(plan.toFetch == [1, 2, 3])
        #expect(plan.reused.isEmpty)
        #expect(!plan.isUpToDate)
    }

    @Test("Only genuinely new UIDs are fetched")
    func fetchesOnlyTheNew() {
        let plan = SyncPlan.plan(cachedUIDs: [1, 2, 3], cachedValidity: 100,
                                 serverUIDs: [1, 2, 3, 4, 5], serverValidity: 100)
        #expect(plan.toFetch == [4, 5])
        #expect(plan.reused == [1, 2, 3])
        #expect(plan.dropped.isEmpty)
    }

    @Test("An unchanged folder fetches nothing at all")
    func noWorkWhenUnchanged() {
        let plan = SyncPlan.plan(cachedUIDs: [7, 8, 9], cachedValidity: 42,
                                 serverUIDs: [7, 8, 9], serverValidity: 42)
        #expect(plan.toFetch.isEmpty)
        #expect(plan.isUpToDate)
    }

    @Test("Mail removed elsewhere is dropped from the cache")
    func dropsWhatTheServerNoLongerLists() {
        let plan = SyncPlan.plan(cachedUIDs: [1, 2, 3], cachedValidity: 100,
                                 serverUIDs: [1, 3], serverValidity: 100)
        #expect(plan.dropped == [2])
        #expect(plan.reused == [1, 3])
        #expect(plan.toFetch.isEmpty)
    }

    /// The one that matters most: reusing a UID across a UIDVALIDITY change
    /// shows one message's contents under another's subject.
    @Test("A UIDVALIDITY change discards the whole cache")
    func uidValidityChangeInvalidates() {
        let plan = SyncPlan.plan(cachedUIDs: [1, 2, 3], cachedValidity: 100,
                                 serverUIDs: [1, 2, 3], serverValidity: 101)
        #expect(plan.invalidated)
        #expect(plan.toFetch == [1, 2, 3])
        #expect(plan.reused.isEmpty)
        #expect(plan.dropped == [1, 2, 3])
    }

    @Test("A server that reports no UIDVALIDITY doesn't nuke the cache")
    func missingValidityIsNotAChange() {
        let plan = SyncPlan.plan(cachedUIDs: [1, 2], cachedValidity: 100,
                                 serverUIDs: [1, 2], serverValidity: nil)
        #expect(!plan.invalidated)
        #expect(plan.reused == [1, 2])
    }

    @Test("Order follows the server's window, not the cache")
    func preservesServerOrder() {
        let plan = SyncPlan.plan(cachedUIDs: [9, 1], cachedValidity: 5,
                                 serverUIDs: [1, 5, 9], serverValidity: 5)
        #expect(plan.toFetch == [5])
        #expect(plan.reused == [1, 9])
    }
}
