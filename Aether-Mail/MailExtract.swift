import Foundation
import EmailKit

/// Structured facts pulled out of prose.
///
/// The premise behind half the Lab: almost every message already contains a
/// hard fact - an amount, a due date, a one-time code, a tracking number - and
/// buries it in a paragraph written for a human. Extraction turns a mailbox into
/// something queryable, and on-device inference means it happens without the
/// mail leaving the phone.
///
/// Regex first for the same reason the scoring is heuristic first: it is
/// instant, deterministic, and works in a Simulator with no model available.
enum MailExtract {

    struct Fact: Identifiable, Hashable {
        enum Kind: String {
            case code      = "Code"
            case amount    = "Amount"
            case tracking  = "Tracking"
            case deadline  = "Deadline"
            case link      = "Action link"

            var icon: String {
                switch self {
                case .code:     return "key.horizontal"
                case .amount:   return "dollarsign.circle"
                case .tracking: return "shippingbox"
                case .deadline: return "clock.badge.exclamationmark"
                case .link:     return "arrow.up.right.square"
                }
            }
        }
        let id = UUID()
        let kind: Kind
        let value: String
        let messageID: String
        let sender: String
        let date: Date?
    }

    /// Ordered most-useful-first, because a one-time code is worthless five
    /// minutes later and an amount owed is not.
    static func facts(in m: MailMessage, body: String?) -> [Fact] {
        let text = (m.subject + " " + (body ?? m.snippet))
        let sender = m.from.first?.shortLabel ?? "unknown"
        var out: [Fact] = []

        func add(_ kind: Fact.Kind, _ value: String) {
            guard !out.contains(where: { $0.kind == kind && $0.value == value }) else { return }
            out.append(Fact(kind: kind, value: value, messageID: m.id, sender: sender, date: m.date))
        }

        // One-time codes: 4-8 digits sitting near the words that introduce them,
        // so an order number or a year is not mistaken for a login code.
        if let codeContext = text.range(of: #"(?i)(code|otp|passcode|verification)[^0-9]{0,24}(\d{4,8})"#,
                                        options: .regularExpression) {
            let chunk = String(text[codeContext])
            if let digits = chunk.range(of: #"\d{4,8}"#, options: .regularExpression) {
                add(.code, String(chunk[digits]))
            }
        }

        // Thousands must be grouped in threes and the match must END on a digit.
        // A looser \d[\d,]* swallowed the separator after the number, so a real
        // inbox produced "$2,300," - trailing comma and a truncated value.
        for match in matches(#"[$£€]\s?\d{1,3}(,\d{3})*(\.\d{2})?\b"#, in: text).prefix(4) {
            add(.amount, match.trimmingCharacters(in: .whitespaces))
        }

        // Carrier formats, validated rather than "any long number".
        //
        // A bare \d{12,22} matched the millisecond Unix timestamps that Google
        // puts in its headers, so a mailbox with no parcels in it reported three
        // tracking numbers - 1787430960453 is a moment in time, not a package.
        for match in matches(#"\b1Z[0-9A-Z]{16}\b"#, in: text).prefix(2) { add(.tracking, match) }
        for match in matches(#"\b(9[2-5]\d{20}|\d{12}|\d{15})\b"#, in: text).prefix(2) where isPlausibleTracking(match) {
            add(.tracking, match)
        }

        // Month names only. An earlier pattern accepted any capitalised word
        // followed by a number, which turned marketing copy like "By sharing 6
        // documents..." into a deadline.
        let months = "jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|jun(e)?|jul(y)?|aug(ust)?|sep(t|tember)?|oct(ober)?|nov(ember)?|dec(ember)?"
        let weekdays = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        for match in matches(#"(?i)\b(due|expires?|deadline|by)\s+(on\s+)?((\#(months))\s+\d{1,2}(,?\s*\d{4})?|\d{1,2}/\d{1,2}(/\d{2,4})?|\d{4}-\d{2}-\d{2}|tomorrow|today|\#(weekdays))\b"#,
                            in: text).prefix(2) {
            add(.deadline, match.trimmingCharacters(in: .whitespaces))
        }

        return out
    }

    /// Rejects numbers that are the right length but obviously not a parcel.
    ///
    /// Epoch milliseconds are thirteen digits and currently begin with 17, which
    /// is exactly the shape of a FedEx number. Anything that reads as a
    /// plausible recent timestamp is far more likely to be one, since carriers
    /// do not encode the current date in their tracking numbers.
    private static func isPlausibleTracking(_ value: String) -> Bool {
        guard let n = Double(value) else { return false }
        if value.count == 13 {
            // 2001-09-09 through roughly 2033, in milliseconds.
            let asDate = n / 1000
            if asDate > 1_000_000_000 && asDate < 2_000_000_000 { return false }
        }
        if value.count == 10 {
            if n > 1_000_000_000 && n < 2_000_000_000 { return false }   // epoch seconds
        }
        // All-identical or sequential digits are test data, not shipments.
        let digits = Array(value)
        if Set(digits).count <= 2 { return false }
        return true
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { r in String(text[r]) }
        }
    }

    // MARK: - Journeys

    /// One real-world event scattered across several messages.
    ///
    /// An order confirmation, a shipping notice, a delivery notice and a receipt
    /// are four inbox rows describing one parcel. Collapsing them is the
    /// difference between a mailbox and a record of what actually happened.
    struct Journey: Identifiable {
        let id: String            // the key everything grouped on
        let title: String
        let messages: [MailMessage]
        let stages: [String]      // ordered, e.g. ordered → shipped → delivered

        var latest: Date? { messages.compactMap(\.date).max() }
        var isComplete: Bool { stages.contains("delivered") || stages.contains("receipt") }
    }

    static func journeys(in messages: [MailMessage]) -> [Journey] {
        var buckets: [String: [MailMessage]] = [:]
        for m in messages {
            // Group by sender domain: a parcel's whole life comes from one
            // company, and subjects change at every stage so they cannot be the
            // key.
            let domain = (m.from.first?.address ?? "").split(separator: "@").last.map(String.init) ?? "unknown"
            let text = (m.subject + " " + m.snippet).lowercased()
            let relevant = ["order", "shipped", "tracking", "delivery", "delivered",
                            "receipt", "invoice", "dispatch", "on its way"]
            guard relevant.contains(where: text.contains) else { continue }
            buckets[domain, default: []].append(m)
        }

        return buckets.compactMap { domain, group -> Journey? in
            guard group.count > 1 else { return nil }   // one message is not a journey
            let sorted = group.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            var stages: [String] = []
            for m in sorted {
                let t = (m.subject + " " + m.snippet).lowercased()
                if t.contains("order") && !stages.contains("ordered") { stages.append("ordered") }
                if (t.contains("shipped") || t.contains("dispatch") || t.contains("on its way"))
                    && !stages.contains("shipped") { stages.append("shipped") }
                if t.contains("out for delivery") && !stages.contains("out for delivery") { stages.append("out for delivery") }
                if t.contains("delivered") && !stages.contains("delivered") { stages.append("delivered") }
                if (t.contains("receipt") || t.contains("invoice")) && !stages.contains("receipt") { stages.append("receipt") }
            }
            return Journey(id: domain,
                           title: sorted.first?.from.first?.shortLabel ?? domain,
                           messages: sorted,
                           stages: stages.isEmpty ? ["update"] : stages)
        }
        .sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
    }

    // MARK: - People

    /// The state of one correspondence, which is what a person actually
    /// remembers about their mail - not individual messages.
    struct Correspondent: Identifiable {
        let id: String            // email address
        let name: String
        let messages: [MailMessage]
        let theyAwaitYou: Int     // unanswered questions from them
        var lastContact: Date? { messages.compactMap(\.date).max() }
        var isAutomated: Bool
    }

    static func people(in scored: [(MailMessage, MailSignal)]) -> [Correspondent] {
        var buckets: [String: [(MailMessage, MailSignal)]] = [:]
        for pair in scored {
            let address = (pair.0.from.first?.address ?? "unknown").lowercased()
            buckets[address, default: []].append(pair)
        }
        return buckets.map { address, group in
            let automated = address.contains("no-reply") || address.contains("noreply")
                || address.contains("notifications@") || address.contains("mailer")
            return Correspondent(
                id: address,
                name: group.first?.0.from.first?.shortLabel ?? address,
                messages: group.map(\.0),
                theyAwaitYou: group.filter { $0.1.needsReply }.count,
                isAutomated: automated
            )
        }
        // Humans waiting on you first; bots last, whatever they claim.
        .sorted {
            if $0.isAutomated != $1.isAutomated { return !$0.isAutomated }
            if $0.theyAwaitYou != $1.theyAwaitYou { return $0.theyAwaitYou > $1.theyAwaitYou }
            return ($0.lastContact ?? .distantPast) > ($1.lastContact ?? .distantPast)
        }
    }
}
