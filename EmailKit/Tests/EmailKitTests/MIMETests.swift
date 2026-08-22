import Testing
import Foundation
@testable import EmailKit

@Suite("MIME encoded words + quoted-printable")
struct MIMEEncodingTests {

    @Test("base64 encoded-word (B)")
    func base64Word() {
        #expect(MIME.decodeWords("=?UTF-8?B?w6ljaG8=?=") == "écho")
    }

    @Test("Q encoded-word with underscore-as-space")
    func qWord() {
        #expect(MIME.decodeWords("=?UTF-8?Q?Caf=C3=A9_time?=") == "Café time")
    }

    @Test("mixed literal + encoded-word runs")
    func mixed() {
        let input = "Re: =?UTF-8?B?w6ljaG8=?= today"
        #expect(MIME.decodeWords(input) == "Re: écho today")
    }

    @Test("plain text passes through unchanged")
    func plain() {
        #expect(MIME.decodeWords("Just a subject") == "Just a subject")
    }

    @Test("quoted-printable soft break + hex")
    func qp() {
        let data = MIME.decodeQuotedPrintable("Caf=C3=A9=\r\n done")
        #expect(String(data: data!, encoding: .utf8) == "Café done")
    }

    @Test("phrase encoding only when non-ASCII")
    func phraseEncode() {
        #expect(MIME.encodePhraseIfNeeded("Ada") == "Ada")
        #expect(MIME.encodePhraseIfNeeded("Café").hasPrefix("=?UTF-8?B?"))
        #expect(MIME.encodePhraseIfNeeded("Doe, John").hasPrefix("\""))
    }

    @Test("HTML strip fallback")
    func htmlStrip() {
        let html = "<html><body><p>Hello</p><p>World &amp; co</p></body></html>"
        let text = MIME.stripHTML(html)
        #expect(text.contains("Hello"))
        #expect(text.contains("World & co"))
    }
}

@Suite("MIME message parser")
struct MIMEMessageParserTests {

    @Test("single-part plain text")
    func plainPart() {
        let raw = "Subject: Hi\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nHello there"
        let body = MIMEMessageParser.parse(raw)
        #expect(body.plainText == "Hello there")
        #expect(body.html == nil)
    }

    @Test("multipart/alternative yields plain + html")
    func alternative() {
        let raw = [
            "Content-Type: multipart/alternative; boundary=\"BND\"",
            "",
            "--BND",
            "Content-Type: text/plain; charset=UTF-8",
            "",
            "plain body",
            "--BND",
            "Content-Type: text/html; charset=UTF-8",
            "",
            "<p>html body</p>",
            "--BND--"
        ].joined(separator: "\r\n")
        let body = MIMEMessageParser.parse(raw)
        #expect(body.plainText == "plain body")
        #expect(body.html == "<p>html body</p>")
    }

    @Test("quoted-printable body is decoded")
    func qpBody() {
        let raw = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCaf=C3=A9"
        let body = MIMEMessageParser.parse(raw)
        #expect(body.plainText == "Café")
    }

    @Test("base64 attachment part is extracted")
    func attachment() {
        let payload = Data("PDFDATA".utf8).base64EncodedString()
        let raw = [
            "Content-Type: multipart/mixed; boundary=\"MIX\"",
            "",
            "--MIX",
            "Content-Type: text/plain",
            "",
            "see attached",
            "--MIX",
            "Content-Type: application/pdf; name=\"doc.pdf\"",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"doc.pdf\"",
            "",
            payload,
            "--MIX--"
        ].joined(separator: "\r\n")
        let body = MIMEMessageParser.parse(raw)
        #expect(body.plainText == "see attached")
        #expect(body.attachments.count == 1)
        #expect(body.attachments.first?.filename == "doc.pdf")
        #expect(body.attachments.first?.data.map { String(data: $0, encoding: .utf8) } == "PDFDATA")
    }
}

@Suite("MIME builder round-trips through the parser")
struct MIMEBuilderTests {

    @Test("plain message builds and re-parses")
    func plainRoundTrip() {
        let msg = OutgoingMessage(
            from: MailAddress(name: "Ada", address: "ada@example.com"),
            to: [MailAddress(address: "bob@example.org")],
            subject: "Café ☕",
            textBody: "Hello, Bob.\nLine two."
        )
        let bytes = MIMEBuilder.build(msg)
        let parsed = MIMEMessageParser.parse(bytes)
        #expect(parsed.plainText?.contains("Hello, Bob.") == true)
        #expect(parsed.plainText?.contains("Line two.") == true)
    }

    @Test("html message produces multipart/alternative")
    func htmlRoundTrip() {
        let msg = OutgoingMessage(
            from: MailAddress(address: "ada@example.com"),
            to: [MailAddress(address: "bob@example.org")],
            subject: "Hi",
            textBody: "plain fallback",
            htmlBody: "<p>rich</p>"
        )
        let bytes = MIMEBuilder.build(msg)
        let parsed = MIMEMessageParser.parse(bytes)
        #expect(parsed.plainText == "plain fallback")
        #expect(parsed.html == "<p>rich</p>")
    }

    @Test("recipients aggregate to + cc + bcc")
    func recipients() {
        let msg = OutgoingMessage(
            from: MailAddress(address: "a@x.com"),
            to: [MailAddress(address: "b@x.com")],
            cc: [MailAddress(address: "c@x.com")],
            bcc: [MailAddress(address: "d@x.com")],
            subject: "s", textBody: "t"
        )
        #expect(msg.envelopeRecipients == ["b@x.com", "c@x.com", "d@x.com"])
    }
}

/// A subject that begins with a non-ASCII character produces a Q-encoded word
/// whose text starts with "=", e.g. "=?UTF-8?q?=E2=80=91S...". A naive search
/// for the "?=" terminator matches the "?" that separates the encoding field
/// from the text, so the word failed to decode and appeared raw on screen -
/// seen in a real inbox as "Your D-U-N=?UTF-8?q?=E2=80=91S=C2=AE_Profile...".
@Suite("Encoded words whose text starts with =")
struct EncodedWordTerminatorTests {

    @Test("Q-encoded text beginning with an escape still decodes")
    func qEncodedLeadingEscape() {
        let raw = "Complete Your D-U-N=?UTF-8?q?=E2=80=91S=C2=AE_Profile?="
        let decoded = MIME.decodeWords(raw)
        #expect(!decoded.contains("=?"))
        #expect(decoded.contains("S"))
    }

    @Test("A normal encoded word is unaffected")
    func plainEncodedWord() {
        #expect(MIME.decodeWords("=?UTF-8?B?SGVsbG8=?=") == "Hello")
    }

    @Test("Text with no encoded word passes through untouched")
    func passthrough() {
        #expect(MIME.decodeWords("Just a subject") == "Just a subject")
    }

    @Test("A malformed word is left alone rather than mangled")
    func malformed() {
        let raw = "=?UTF-8?onlytwo?="
        #expect(MIME.decodeWords(raw).contains("=?"))
    }
}
