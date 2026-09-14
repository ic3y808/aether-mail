import SwiftUI
import EmailKit

/// A place to try email UIs against real mail without committing to any of them.
///
/// Everything here is disposable: one folder, one entry point, no other file
/// depends on it. Pick an experiment from the bar and the same inbox is
/// re-presented underneath it.
struct MailLabView: View {
    @Environment(MailStore.self) private var store
    @State private var experiment: LabExperiment = .today
    /// Falls back to a fixed sample mailbox when there is no account - which is
    /// always true in the Simulator, and is also the only way to compare two
    /// ranking UIs fairly, since a live inbox changes under you.
    @State private var useSample = false
    @State private var showingSettings = false

    enum LabExperiment: String, CaseIterable, Identifiable {
        case today      = "Today"
        case drafts     = "Drafts"
        case priority   = "Priority"
        case deck       = "Deck"
        case facts      = "Facts"
        case journeys   = "Journeys"
        case people     = "People"
        case categories = "Shelves"
        case commitments = "Owed"
        case reader     = "Reader"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .today:       return "sun.horizon"
            case .drafts:      return "square.and.pencil"
            case .facts:       return "doc.text.magnifyingglass"
            case .journeys:    return "point.topleft.down.to.point.bottomright.curvepath"
            case .people:      return "person.2"
            case .priority:    return "arrow.up.circle"
            case .deck:        return "rectangle.stack"
            case .categories:  return "square.grid.2x2"
            case .commitments: return "checklist"
            case .reader:      return "text.alignleft"
            }
        }

        var blurb: String {
            switch self {
            case .today:       return "The whole mailbox as one briefing. Open the list only if this is wrong."
            case .drafts:      return "Replies written for you. Approve, adjust or skip - nothing is sent."
            case .facts:       return "Codes, amounts, dates and tracking numbers - lifted out of the prose."
            case .journeys:    return "One parcel, not four emails. Order, shipped, delivered, receipt."
            case .people:      return "The mailbox as relationships: who's waiting, who's a machine."
            case .priority:    return "What actually needs you, floated to the top with the reason why."
            case .deck:        return "One message at a time. Swipe to clear the backlog."
            case .categories:  return "Sorted into shelves by what the mail IS, not when it came."
            case .commitments: return "Promises you made, pulled out of your own sent replies."
            case .reader:      return "A calm vertical feed for the stuff you read, not answer."
            }
        }
    }

    private var source: [MailMessage] {
        #if targetEnvironment(simulator)
        return (useSample || store.inbox.isEmpty) ? LabSampleMail.inbox() : store.inbox
        #else
        // On a device the Lab only ever shows real mail. An empty result is the
        // honest answer, not a reason to invent one.
        return store.inbox
        #endif
    }

    /// Scoring is cached, not computed in `body`.
    ///
    /// It used to be a computed property, which SwiftUI re-evaluates on every
    /// redraw - and the full-text warm-up publishes progress once per message.
    /// Sixty-eight fetches therefore re-scored sixty-eight messages each time,
    /// running regex over every downloaded body, and the whole app crawled.
    @State private var scored: [(MailMessage, MailSignal)] = []

    /// Changes exactly when the scoring inputs change: which mailbox, how many
    /// messages, and how many bodies have arrived.
    private var inputSignature: String {
        "\(useSample)-\(store.inbox.count)-\(store.openBodies.count)"
    }

    private func rescore() {
        #if targetEnvironment(simulator)
        let sample = useSample || store.inbox.isEmpty
        #else
        let sample = false
        #endif
        scored = source.map { m in
            // Sample mail carries its text in the snippet, since nothing fetched
            // a body for it.
            let text = sample ? m.snippet : store.body(for: m)?.bestText
            return (m, MailInsight.signal(for: m, bodyText: text))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().opacity(0.3)
            Group {
                switch experiment {
                case .today:       TodayBriefing(items: scored)
                case .drafts:      DraftQueue(items: scored)
                case .facts:       FactsView(items: scored)
                case .journeys:    JourneysView(items: scored)
                case .people:      PeopleView(items: scored)
                case .priority:    PriorityFeed(items: scored)
                case .deck:        TriageDeck(items: scored)
                case .categories:  ShelvesView(items: scored)
                case .commitments: CommitmentsView(items: scored)
                case .reader:      ReaderFeed(items: scored)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { AuroraBackdrop(intensity: 0.7) }
        // Recompute only when the inputs actually change, not on every redraw.
        .task(id: inputSignature) { rescore() }
        .navigationTitle("Lab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showingSettings) {
            LabSettingsView().environment(store)
        }
    }

    private var picker: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LabExperiment.allCases) { e in
                        Button {
                            withAnimation(.snappy) { experiment = e }
                        } label: {
                            Label(e.rawValue, systemImage: e.icon)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background {
                                    if experiment == e {
                                        Capsule().fill(LinearGradient.aether)
                                    } else {
                                        Capsule().fill(.ultraThinMaterial)
                                    }
                                }
                                .foregroundStyle(experiment == e ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            HStack {
                Text(experiment.blurb)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Fabricated mail is a Simulator affordance. On a real device it
                // sits next to a real mailbox, and a toggle that silently swaps
                // invented messages for the owner's own is a good way to act on
                // something that was never real.
                #if targetEnvironment(simulator)
                if !store.inbox.isEmpty {
                    Toggle("Sample", isOn: $useSample)
                        .toggleStyle(.button)
                        .font(.caption2)
                        .tint(Color.aetherViolet)
                } else {
                    Label("sample mailbox", systemImage: "flask")
                        .font(.caption2).foregroundStyle(Color.aetherViolet)
                }
                #endif
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 1. Priority

/// Ranked by what the app thinks needs a person, each row carrying the reason
/// it was ranked that way - so a wrong guess is visibly wrong instead of
/// mysterious.
private struct PriorityFeed: View {
    let items: [(MailMessage, MailSignal)]

    private var ranked: [(MailMessage, MailSignal)] {
        items.sorted { $0.1.urgency > $1.1.urgency }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(ranked.enumerated()), id: \.element.0.id) { idx, pair in
                    let (m, s) = pair
                    if idx == 0 || (ranked[idx - 1].1.urgency >= 55 && s.urgency < 55) {
                        HStack {
                            Text(s.urgency >= 55 ? "NEEDS YOU" : "THE REST")
                                .font(.caption2.weight(.bold)).kerning(1.4)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, idx == 0 ? 4 : 14)
                    }
                    NavigationLink { ReadingView(message: m) } label: {
                        HStack(spacing: 12) {
                            UrgencyDial(value: s.urgency)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.from.first?.shortLabel ?? "unknown")
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                Text(s.reason)
                                    .font(.caption2)
                                    .foregroundStyle(Color.aetherViolet)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .glassCard(16)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

private struct UrgencyDial: View {
    let value: Int
    private var tint: Color {
        value >= 70 ? .aetherMagenta : value >= 45 ? .aetherViolet : .secondary
    }
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(value) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)").font(.caption2.weight(.bold)).foregroundStyle(tint)
        }
        .frame(width: 38, height: 38)
    }
}

// MARK: - 2. Deck

/// One message, full attention, a decision, next. The opposite of a list: you
/// cannot skim past things, which is the point when clearing a backlog.
private struct TriageDeck: View {
    @Environment(MailStore.self) private var store
    let items: [(MailMessage, MailSignal)]
    @State private var index = 0
    @State private var drag: CGSize = .zero

    private var queue: [(MailMessage, MailSignal)] {
        items.filter { $0.0.isUnread }.sorted { $0.1.urgency > $1.1.urgency }
    }

    var body: some View {
        VStack {
            if index >= queue.count {
                ContentUnavailableView("Deck clear", systemImage: "checkmark.circle",
                                       description: Text("Nothing unread left to triage."))
            } else {
                let (m, s) = queue[index]
                Spacer(minLength: 0)
                card(m, s)
                    .offset(x: drag.width, y: drag.height * 0.3)
                    .rotationEffect(.degrees(Double(drag.width / 22)))
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { value in
                                let threshold: CGFloat = 110
                                if value.translation.width < -threshold {
                                    store.requestDelete([m]); advance()
                                } else if value.translation.width > threshold {
                                    store.archive([m]); advance()
                                } else {
                                    withAnimation(.snappy) { drag = .zero }
                                }
                            }
                    )
                Spacer(minLength: 0)
                HStack(spacing: 26) {
                    deckButton("trash", .red) { store.requestDelete([m]); advance() }
                    deckButton("envelope.open", .secondary) { store.setRead(m, true); advance() }
                    deckButton("archivebox", .indigo) { store.archive([m]); advance() }
                }
                .padding(.bottom, 24)
                Text("\(index + 1) of \(queue.count)")
                    .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }
    }

    private func advance() {
        withAnimation(.snappy) { drag = .zero; index += 1 }
    }

    private func deckButton(_ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 56, height: 56)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(tint.opacity(0.35)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func card(_ m: MailMessage, _ s: MailSignal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(s.category.rawValue, systemImage: s.category.icon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient.aether.opacity(0.85)))
                    .foregroundStyle(.white)
                Spacer()
                UrgencyDial(value: s.urgency)
            }
            Text(m.from.first?.shortLabel ?? "unknown")
                .font(.headline)
            Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                .font(.title3.weight(.semibold))
                .lineLimit(4)
            Text(s.reason).font(.caption).foregroundStyle(Color.aetherViolet)
            Spacer(minLength: 0)
            Text("← delete    ·    archive →")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .glassCard(24)
        .padding(.horizontal, 20)
    }
}

// MARK: - 3. Shelves

/// Grouped by what a message IS rather than when it arrived, because a receipt
/// and a question from a person are not the same kind of object.
private struct ShelvesView: View {
    let items: [(MailMessage, MailSignal)]

    private var shelves: [(MailCategory, [(MailMessage, MailSignal)])] {
        MailCategory.allCases.compactMap { cat in
            let group = items.filter { $0.1.category == cat }
                .sorted { $0.1.urgency > $1.1.urgency }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(shelves, id: \.0) { cat, group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(cat.rawValue, systemImage: cat.icon)
                                .font(.subheadline.weight(.bold))
                            Text("\(group.count)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(.ultraThinMaterial))
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(group, id: \.0.id) { m, s in
                                    NavigationLink { ReadingView(message: m) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(m.from.first?.shortLabel ?? "unknown")
                                                .font(.caption.weight(.semibold)).lineLimit(1)
                                            Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                                .font(.footnote).lineLimit(3)
                                                .foregroundStyle(.secondary)
                                            Spacer(minLength: 0)
                                            if m.isUnread {
                                                Circle().fill(Color.aetherMagenta)
                                                    .frame(width: 6, height: 6)
                                            }
                                        }
                                        .padding(12)
                                        .frame(width: 190, height: 118, alignment: .topLeading)
                                        .glassCard(16)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: - 4. Owed

/// Two lists nobody's mail client keeps: what you owe other people, and what
/// they owe you. Both are already in the mailbox; neither is ever surfaced.
private struct CommitmentsView: View {
    let items: [(MailMessage, MailSignal)]

    private var youOwe: [(MailMessage, MailSignal)] { items.filter { $0.1.needsReply } }
    private var youPromised: [(MailMessage, MailSignal)] { items.filter { $0.1.isCommitment } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("They're waiting on you", "arrow.uturn.left", youOwe,
                        empty: "Nobody is waiting on a reply.")
                section("You said you would", "hand.raised", youPromised,
                        empty: "No promises found in this mailbox.")
            }
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ icon: String,
                         _ group: [(MailMessage, MailSignal)], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 16)
            if group.isEmpty {
                Text(empty).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ForEach(group, id: \.0.id) { m, _ in
                    NavigationLink { ReadingView(message: m) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "circle")
                                .foregroundStyle(Color.aetherViolet)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                    .font(.footnote.weight(.medium)).lineLimit(2)
                                Text(m.from.first?.shortLabel ?? "unknown")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if let d = m.date {
                                Text(d, style: .relative)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .glassCard(14)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 5. Reader

/// The stuff you read rather than answer, presented like a feed instead of a
/// queue - nothing to clear, no unread count, just newest first.
private struct ReaderFeed: View {
    @Environment(MailStore.self) private var store
    let items: [(MailMessage, MailSignal)]

    private var reading: [(MailMessage, MailSignal)] {
        items.filter { $0.1.category == .newsletter || $0.1.urgency < 35 }
            .sorted { ($0.0.date ?? .distantPast) > ($1.0.date ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(reading, id: \.0.id) { m, _ in
                    NavigationLink { ReadingView(message: m) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                GlowOrb(systemImage: "newspaper", size: 26)
                                Text(m.from.first?.shortLabel ?? "unknown")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if let d = m.date {
                                    Text(d, style: .relative)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                .font(.headline).lineLimit(3)
                            if let summary = store.summary(for: m.id) {
                                Text(summary)
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(20)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
        }
    }
}
