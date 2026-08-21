import Testing
@testable import EmailKit

/// Filing mail is the whole point of a mail client, and it was broken on every
/// provider tested here: the resolver invented folder names the servers did not
/// have, so archive/junk/trash all failed with an IMAP NO.
@Suite("Resolving special folders")
struct FolderResolutionTests {

    // Real layouts. Gmail namespaces under "[Gmail]/" and has NO Archive;
    // iCloud calls trash "Deleted Messages"; Dovecot namespaces under "INBOX.".
    let gmail = [
        MailFolder(path: "INBOX", role: .inbox),
        MailFolder(path: "[Gmail]/All Mail", role: .all),
        MailFolder(path: "[Gmail]/Trash", role: .trash),
        MailFolder(path: "[Gmail]/Spam", role: .junk),
        MailFolder(path: "[Gmail]/Sent Mail", role: .sent)
    ]
    let icloud = [
        MailFolder(path: "INBOX", role: .inbox),
        MailFolder(path: "Archive", role: .archive),
        MailFolder(path: "Deleted Messages", role: .trash),
        MailFolder(path: "Junk", role: .junk)
    ]
    /// A server that advertises no special-use flags at all, so every role must
    /// come from the name.
    let dovecotNoFlags = [
        MailFolder(path: "INBOX", role: .other),
        MailFolder(path: "INBOX.Trash", role: .other),
        MailFolder(path: "INBOX.Junk", role: .other),
        MailFolder(path: "INBOX.Archive", role: .other)
    ]

    @Test("Gmail archives into All Mail, because it has no Archive folder")
    func gmailArchive() {
        // The bug: no folder had role .archive, the name list was compared
        // against the FULL path, and the resolver returned nil - so Archive was
        // permanently "no such folder" on Gmail.
        #expect(MailFolder.resolve(.archive, in: gmail)?.path == "[Gmail]/All Mail")
    }

    @Test("Gmail's namespaced trash and spam resolve")
    func gmailTrashJunk() {
        #expect(MailFolder.resolve(.trash, in: gmail)?.path == "[Gmail]/Trash")
        #expect(MailFolder.resolve(.junk, in: gmail)?.path == "[Gmail]/Spam")
    }

    @Test("iCloud's trash is Deleted Messages, not Trash")
    func icloudTrash() {
        // Guessing the literal "Trash" here is what made every delete fail.
        #expect(MailFolder.resolve(.trash, in: icloud)?.path == "Deleted Messages")
        #expect(MailFolder.resolve(.archive, in: icloud)?.path == "Archive")
    }

    @Test("a server with no special-use flags resolves by leaf name")
    func nameFallback() {
        #expect(MailFolder.resolve(.trash, in: dovecotNoFlags)?.path == "INBOX.Trash")
        #expect(MailFolder.resolve(.junk, in: dovecotNoFlags)?.path == "INBOX.Junk")
        #expect(MailFolder.resolve(.archive, in: dovecotNoFlags)?.path == "INBOX.Archive")
    }

    @Test("an unknown folder list yields nil rather than an invented name")
    func neverInvents() {
        // The old code returned "Trash" for an empty list. Firing UID MOVE at a
        // folder that does not exist is worse than reporting there is none:
        // the user sees an IMAP error instead of a sentence.
        #expect(MailFolder.resolve(.trash, in: []) == nil)
        let sparse = [MailFolder(path: "INBOX", role: .inbox)]
        #expect(MailFolder.resolve(.trash, in: sparse) == nil)
        #expect(MailFolder.resolve(.archive, in: sparse) == nil)
    }

    @Test("leafName strips both IMAP separators")
    func leaf() {
        #expect(MailFolder(path: "[Gmail]/Trash").leafName == "Trash")
        #expect(MailFolder(path: "INBOX.Junk").leafName == "Junk")
        #expect(MailFolder(path: "Archive").leafName == "Archive")
    }

    @Test("a real special-use flag always wins over a matching name")
    func flagBeatsName() {
        // A user folder literally called "Archive" must not outrank the folder
        // the server flagged \Archive.
        let folders = [
            MailFolder(path: "Archive", role: .other),
            MailFolder(path: "Storage/Old", role: .archive)
        ]
        #expect(MailFolder.resolve(.archive, in: folders)?.path == "Storage/Old")
    }
}
