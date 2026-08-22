import Testing
import Foundation
@testable import EmailKit

/// `execute` returns the tagged response whatever its status, and the read
/// commands used to discard it — so a server `NO`/`BAD` came back as an empty
/// result, indistinguishable from a genuinely empty mailbox or a blank email.
///
/// That was survivable while nothing was persisted. Once a disk cache landed,
/// those empties became permanent: an empty body was written to the cache and
/// served forever, and an empty folder list overwrote a good one. These pin the
/// rule that a failed command throws rather than returning nothing.
@Suite("Failed IMAP commands throw rather than returning empty")
struct SilentFailureTests {

    /// Greeting + LOGIN + SELECT, so each test only has to script its own command.
    private static func connected(_ tail: [String]) async throws -> IMAPClient {
        let t = ScriptedTransport(script: [
            "* OK [CAPABILITY IMAP4rev1] ready\r\n",
            "A0001 OK LOGIN completed\r\n",
            "* 3 EXISTS\r\n* OK [UIDVALIDITY 42] ok\r\nA0002 OK [READ-WRITE] done\r\n",
        ] + tail)
        let client = IMAPClient(transport: t)
        try await client.connect()
        try await client.login(user: "a@b.c", password: "pw")
        _ = try await client.select("INBOX")
        return client
    }

    /// The one that produced the user-visible "(no content)": a failed body
    /// fetch returned zero bytes, the MIME parser turned that into an empty
    /// MailBody, and the caller cached it as a successful result.
    @Test("A NO on the body fetch throws instead of returning 0 bytes")
    func failedBodyFetchThrows() async throws {
        let client = try await Self.connected(["A0003 NO [SERVERBUG] Internal error\r\n"])
        await #expect(throws: IMAPClientError.self) {
            _ = try await client.fetchRawMessage(uid: 7)
        }
    }

    /// An OK response that carried no BODY[] section is a parse miss, not a
    /// blank email — and must not be cached as one.
    @Test("An OK fetch with no BODY[] section throws")
    func emptyBodySectionThrows() async throws {
        let client = try await Self.connected(["A0003 OK FETCH completed\r\n"])
        await #expect(throws: IMAPClientError.self) {
            _ = try await client.fetchRawMessage(uid: 7)
        }
    }

    /// Returning [] here made `sync` believe the account's inbox was empty and
    /// commit that to disk, wiping the cached list.
    @Test("A failed SEARCH throws instead of reporting an empty mailbox")
    func failedSearchThrows() async throws {
        let client = try await Self.connected(["A0003 BAD Invalid search criteria\r\n"])
        await #expect(throws: IMAPClientError.self) {
            _ = try await client.uidSearch("ALL")
        }
    }

    @Test("A failed summary fetch throws instead of returning no messages")
    func failedSummaryFetchThrows() async throws {
        let client = try await Self.connected(["A0003 NO Server busy\r\n"])
        await #expect(throws: IMAPClientError.self) {
            _ = try await client.fetchSummaries(uidSet: "1:5")
        }
    }

    /// A failed LIST used to return no folders, which overwrote the cached
    /// folder list and left the mailboxes screen empty.
    @Test("A failed LIST throws instead of reporting no folders")
    func failedListThrows() async throws {
        let t = ScriptedTransport(script: [
            "* OK [CAPABILITY IMAP4rev1] ready\r\n",
            "A0001 OK LOGIN completed\r\n",
            "A0002 NO Cannot list folders right now\r\n",
        ])
        let client = IMAPClient(transport: t)
        try await client.connect()
        try await client.login(user: "a@b.c", password: "pw")
        await #expect(throws: IMAPClientError.self) {
            _ = try await client.listFolders()
        }
    }

    /// The flip side: a genuinely empty result on an OK response is still a
    /// legitimate answer, and must not start throwing.
    @Test("A genuinely empty mailbox still returns empty, not an error")
    func emptyMailboxIsNotAnError() async throws {
        let client = try await Self.connected(["* SEARCH\r\nA0003 OK SEARCH completed\r\n"])
        let uids = try await client.uidSearch("ALL")
        #expect(uids.isEmpty)
    }
}
