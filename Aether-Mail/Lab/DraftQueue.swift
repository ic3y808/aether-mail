import SwiftUI
import EmailKit

/// The inbox as a queue of drafts to approve, rather than messages to read.
///
/// The bet behind it: for most mail that needs a human, the reply is short and
/// predictable, and the expensive part is not writing it - it is the context
/// switch of opening a message, working out what it wants, and composing from
/// nothing. If the machine has already read it and proposed an answer, the job
/// becomes approve, adjust, or skip.
///
/// Nothing is sent. There is no send button and no SMTP call: drafts are for
/// reading and copying, because a queue that fires mail off on a tap is exactly
/// the wrong thing to build before the drafts are trustworthy.
struct DraftQueue: View {
    @Environment(MailStore.self) private var store
    let items: [(MailMessage, MailSignal)]

    @State private var drafts: [String: String] = [:]
    @State private var generating: Set<String> = []
    @State private var edited: [String: String] = [:]
    @State private var inference = LabInference.shared

    /// Only mail a person is actually waiting on. Drafting replies to
    /// newsletters would be worse than useless.
    private var queue: [(MailMessage, MailSignal)] {
        items
            // Never draft to a machine. Urgency alone let a no-reply 2FA mail
            // into the queue, and the model dutifully wrote "Thank you for the
            // verification code" to an address that discards it.
            .filter { !$0.1.isAutomated }
            .filter { $0.1.needsReply || ($0.1.urgency >= 60 && !$0.1.isCommitment) }
            .sorted { $0.1.urgency > $1.1.urgency }
    }

    var body: some View {
        // The picker sits above the queue, not inside it: choosing which model
        // writes - and scanning for one - has to be possible even when there is
        // nothing to answer, which on a mailbox full of marketing is most of the
        // time.
        VStack(spacing: 0) {
            brainNote
                .padding(.top, 10)
                .padding(.bottom, 6)
            if queue.isEmpty {
                ContentUnavailableView("Nothing to answer", systemImage: "checkmark.bubble",
                                       description: Text("No mail here is waiting on a reply from you."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if !MailAI.isAvailable {
                            Label("On-device model unavailable here — showing scaffolds instead of written replies.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 18)
                        }
                        ForEach(queue, id: \.0.id) { m, s in
                            card(m, s)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .task(id: queue.count) { await generateAll() }
    }

    /// Which model is writing, stated but not chosen here - the control lives
    /// in Lab Settings, so it is in one place rather than in whichever screen
    /// happened to need it.
    @ViewBuilder
    private var brainNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.caption2)
            Text(inference.selected.map { $0.best ?? $0.engine } ?? "This iPhone · ~3B")
                .font(.caption2.weight(.semibold))
            Text("· change in Lab Settings")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(Color.aetherViolet)
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func card(_ m: MailMessage, _ s: MailSignal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GlowOrb(systemImage: "arrowshape.turn.up.left", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.from.first?.shortLabel ?? "unknown")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let d = m.date {
                    Text(d, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Text(s.reason)
                .font(.caption2).foregroundStyle(Color.aetherViolet)

            Divider().opacity(0.25)

            if generating.contains(m.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drafting on device…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                // Editable: a draft you cannot change is a suggestion you have
                // to retype, which is worse than no draft at all.
                TextEditor(text: Binding(
                    get: { edited[m.id] ?? drafts[m.id] ?? "" },
                    set: { edited[m.id] = $0 }
                ))
                .font(.footnote)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 92)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = edited[m.id] ?? drafts[m.id] ?? ""
                    store.banner = "Draft copied."
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption.weight(.semibold))
                }
                Button {
                    Task { await generate(m, s, force: true) }
                } label: {
                    Label("Redraft", systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
                }
                Spacer()
                Button {
                    store.setRead(m, true)
                } label: {
                    Label("Skip", systemImage: "xmark").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.aetherViolet)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
        .padding(.horizontal, 14)
    }

    /// One instruction, used by whichever model is writing.
    ///
    /// The first version said "answer what was asked", which for "what tolerance
    /// did you want?" can only be satisfied by inventing one - and the 3B model
    /// duly produced "+/- 0.01 inches ... by 2:00 pm tomorrow", neither of which
    /// appeared in the message. The failure was the prompt's, not the model's.
    private var groundedInstruction: String {
        """
        Write ONLY the body of a reply to this email, in the first person, as the \
        recipient. Two or three sentences, and it must read as a complete message.

        Rules:
        - Use ONLY facts stated in the email itself. Never invent a number, date, \
          price, quantity or commitment.
        - If it asks something only the recipient could know, do not answer it: \
          write a full sentence around a square-bracket blank, for example \
          "The tolerance we need is [tolerance]." Never reply with a bracket alone.
        - Refer only to this email's own subject. Do not mention anything from \
          another message.
        - No preamble such as "Here is a draft". No greeting, no sign-off, no \
          subject line, no quotation marks around the reply.
        - Output the reply text and nothing else.
        """
    }

    private func generateAll() async {
        // Sequential and capped: on-device inference competes with the UI for
        // the same silicon, and drafting forty replies nobody asked for is how
        // a nice idea becomes a hot phone.
        for (m, s) in queue.prefix(8) where drafts[m.id] == nil {
            await generate(m, s)
        }
    }

    private func generate(_ m: MailMessage, _ s: MailSignal, force: Bool = false) async {
        guard force || drafts[m.id] == nil else { return }
        guard !generating.contains(m.id) else { return }
        generating.insert(m.id)
        defer { generating.remove(m.id) }

        let body = store.body(for: m)?.bestText ?? m.snippet

        // A LAN model first when one is chosen; the phone is the fallback, so a
        // Mac that went to sleep mid-queue degrades instead of failing.
        if inference.selected != nil, !body.isEmpty {
            let user = "From: \(m.from.first?.shortLabel ?? "unknown")\nSubject: \(m.subject)\n\n\(String(body.prefix(4000)))"
            if let written = await inference.complete(system: groundedInstruction, user: user) {
                drafts[m.id] = Self.stripPreamble(written)
                return
            }
        }

        if MailAI.isAvailable, !body.isEmpty {
            // The first version of this said "answer what was asked", which for
            // a question like "what tolerance did you want?" can only be
            // satisfied by inventing one - and the model duly produced
            // "+/- 0.01 inches ... by 2:00 pm tomorrow", neither of which
            // appeared anywhere in the message. The failure was the prompt's,
            // not the model's: it was told to answer something it could not know.
            //
            // So: never introduce a fact, defer instead, and leave a bracketed
            // blank where a decision belongs. A draft with an honest gap is
            // useful; a draft with a confident wrong number is a liability.
            let instruction = groundedInstruction
            if let written = await MailAI.ask(instruction,
                                              subject: m.subject,
                                              from: m.from.first?.shortLabel ?? "unknown",
                                              body: body) {
                drafts[m.id] = Self.stripPreamble(written)
                return
            }
        }
        drafts[m.id] = scaffold(for: m, s)
    }

    /// Removes the model talking to *us* rather than writing as the user.
    ///
    /// Instructions alone do not reliably suppress "Sure, here is a draft reply:"
    /// followed by the actual reply in quotes, so the shape is stripped after the
    /// fact as well as forbidden in the prompt.
    static func stripPreamble(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A lead-in line ending in a colon, before a blank line.
        if let firstBreak = out.range(of: "\n\n") {
            let lead = out[out.startIndex..<firstBreak.lowerBound]
            let lowered = lead.lowercased()
            let isPreamble = lead.count < 90 && lead.hasSuffix(":")
                && (lowered.contains("draft") || lowered.contains("reply")
                    || lowered.contains("here is") || lowered.contains("sure"))
            if isPreamble { out = String(out[firstBreak.upperBound...]) }
        }

        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wrapping quotes around the whole body.
        if out.count > 1, out.hasPrefix("\""), out.hasSuffix("\"") {
            out = String(out.dropFirst().dropLast())
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to show when there is no model: a shaped starting point rather than
    /// an empty box, and obviously a scaffold so nobody mistakes it for writing.
    private func scaffold(for m: MailMessage, _ s: MailSignal) -> String {
        let who = m.from.first?.name?.split(separator: " ").first.map(String.init)
        let name = who.map { " \($0)" } ?? ""
        if s.needsReply {
            return "Thanks\(name) — [answer the question]. I'll follow up by [date] if anything changes."
        }
        if s.category == .money {
            return "Thanks\(name) — received. [confirm or query the amount]."
        }
        return "Thanks\(name) — [acknowledge]. [next step]."
    }
}
