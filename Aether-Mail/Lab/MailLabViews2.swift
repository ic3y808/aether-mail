import SwiftUI
import EmailKit

// MARK: - Today

/// One screen that answers "what do I need to know", instead of a list you have
/// to read to find out. The 2030 bet: the inbox is a briefing, and the list is
/// something you open only when the briefing is wrong.
struct TodayBriefing: View {
    @Environment(MailStore.self) private var store
    let items: [(MailMessage, MailSignal)]

    private var needsYou: [(MailMessage, MailSignal)] { items.filter { $0.1.urgency >= 55 } }
    private var awaiting: [(MailMessage, MailSignal)] { items.filter { $0.1.needsReply } }
    @State private var deadlines: [MailExtract.Fact] = []

    private func extractDeadlines() {
        deadlines = items
            .flatMap { MailExtract.facts(in: $0.0, body: store.body(for: $0.0)?.bestText ?? $0.0.snippet) }
            .filter { $0.kind == .deadline }
    }
    private var handled: Int { items.filter { !$0.0.isUnread }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(), format: .dateTime.weekday(.wide).month().day())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(headline)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)

                HStack(spacing: 10) {
                    stat("\(needsYou.count)", "need you", .aetherMagenta)
                    stat("\(awaiting.count)", "awaiting reply", .aetherViolet)
                    stat("\(handled)", "handled", .secondary)
                }
                .padding(.horizontal, 14)

                if !deadlines.isEmpty {
                    block("Dates mentioned", "clock.badge.exclamationmark") {
                        ForEach(deadlines.prefix(4)) { f in
                            HStack {
                                Text(f.value).font(.footnote.weight(.medium))
                                Spacer()
                                Text(f.sender).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !needsYou.isEmpty {
                    block("Worth your attention", "exclamationmark.circle") {
                        ForEach(needsYou.prefix(4), id: \.0.id) { m, s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                    .font(.footnote.weight(.medium)).lineLimit(1)
                                Text("\(m.from.first?.shortLabel ?? "unknown") · \(s.reason)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 14)
        }
        .task(id: items.count) { extractDeadlines() }
    }

    private var headline: String {
        if needsYou.isEmpty && awaiting.isEmpty { return "Nothing needs you right now." }
        if needsYou.isEmpty { return "\(awaiting.count) people are waiting on a reply." }
        return "\(needsYou.count) things need you, and \(awaiting.count) people are waiting."
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.weight(.bold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassCard(16)
    }

    @ViewBuilder
    private func block<C: View>(_ title: String, _ icon: String,
                                @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(18)
        .padding(.horizontal, 14)
    }
}

// MARK: - Facts

/// Just the hard information, stripped of the prose it arrived in. Codes,
/// amounts, tracking numbers, dates - the parts anyone actually opens mail to
/// find.
struct FactsView: View {
    @Environment(MailStore.self) private var store
    let items: [(MailMessage, MailSignal)]

    /// Cached: extraction runs NSRegularExpression over every downloaded body,
    /// which is far too expensive to redo on each redraw.
    @State private var facts: [MailExtract.Fact] = []

    private func extract() {
        facts = items
            .flatMap { MailExtract.facts(in: $0.0, body: store.body(for: $0.0)?.bestText ?? $0.0.snippet) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var grouped: [(MailExtract.Fact.Kind, [MailExtract.Fact])] {
        let order: [MailExtract.Fact.Kind] = [.code, .deadline, .amount, .tracking, .link]
        return order.compactMap { kind in
            let g = facts.filter { $0.kind == kind }
            return g.isEmpty ? nil : (kind, g)
        }
    }

    var body: some View {
        if facts.isEmpty {
            ContentUnavailableView("No facts found", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Nothing in this mailbox had a code, amount, date or tracking number."))
                .task(id: items.count) { extract() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.0) { kind, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(kind.rawValue, systemImage: kind.icon)
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 16)
                            ForEach(group) { f in
                                HStack(spacing: 12) {
                                    Text(f.value)
                                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(f.sender).font(.caption2).lineLimit(1)
                                        if let d = f.date {
                                            Text(d, style: .relative)
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                                .glassCard(14)
                                .padding(.horizontal, 14)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .task(id: items.count) { extract() }
        }
    }
}

// MARK: - Journeys

/// Four messages about one parcel, shown as one parcel.
struct JourneysView: View {
    let items: [(MailMessage, MailSignal)]

    private var journeys: [MailExtract.Journey] {
        MailExtract.journeys(in: items.map(\.0))
    }

    var body: some View {
        if journeys.isEmpty {
            ContentUnavailableView("No journeys yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                   description: Text("Orders, shipping and receipts from one sender get collapsed here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(journeys) { j in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(j.title).font(.headline)
                                Spacer()
                                if j.isComplete {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            // The track: every stage this thing has been through.
                            HStack(spacing: 0) {
                                ForEach(Array(j.stages.enumerated()), id: \.offset) { idx, stage in
                                    if idx > 0 {
                                        Rectangle().fill(LinearGradient.aether)
                                            .frame(height: 2)
                                    }
                                    VStack(spacing: 4) {
                                        Circle().fill(LinearGradient.aether)
                                            .frame(width: 10, height: 10)
                                        Text(stage).font(.caption2).foregroundStyle(.secondary)
                                            .fixedSize()
                                    }
                                }
                            }
                            Text("\(j.messages.count) messages")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassCard(20)
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - People

/// The mailbox as relationships rather than messages: who is waiting on you,
/// who you last heard from, and which senders are machines.
struct PeopleView: View {
    let items: [(MailMessage, MailSignal)]

    private var people: [MailExtract.Correspondent] { MailExtract.people(in: items) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(people) { p in
                    HStack(spacing: 12) {
                        GlowOrb(systemImage: p.isAutomated ? "gearshape" : "person.fill", size: 40)
                            .opacity(p.isAutomated ? 0.45 : 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text("\(p.messages.count) messages")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let d = p.lastContact {
                                    Text("·").font(.caption2).foregroundStyle(.secondary)
                                    Text(d, style: .relative)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        if p.theyAwaitYou > 0 {
                            Text("\(p.theyAwaitYou) waiting")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(LinearGradient.aether))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(12)
                    .glassCard(16)
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 12)
        }
    }
}
