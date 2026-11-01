import SwiftUI
import EmailKit

/// Priority: The inbox sorted strictly by what needs human attention,
/// each carrying the exact reason why with interactive urgency dials and swipe actions.
struct PriorityView: View {
    @Environment(MailStore.self) private var store
    @AppStorage("priority.onlyNeedsYou") private var onlyNeedsYou = false

    private var items: [MailMessage] { store.inbox }

    private var ranked: [(MailMessage, MailSignal)] {
        let scored = items.map { ($0, store.signal(for: $0)) }
            .sorted { $0.1.urgency > $1.1.urgency }
        if onlyNeedsYou {
            return scored.filter { $0.1.urgency >= 55 }
        }
        return scored
    }

    private var urgentCount: Int {
        items.filter { store.signal(for: $0).urgency >= 55 }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                // Priority summary bar
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(Color.aetherMagenta)
                        Text("\(urgentCount) Urgent")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))

                    Spacer()

                    Toggle("Only Needs Action", isOn: $onlyNeedsYou)
                        .toggleStyle(.button)
                        .font(.caption2.weight(.medium))
                        .tint(Color.aetherMagenta)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if ranked.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(LinearGradient.aether)
                            .padding(.top, 24)
                        Text("No Urgent Mail")
                            .font(.headline)
                        Text("Everything in your inbox has been reviewed or doesn't require immediate action.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.vertical, 24)
                } else {
                    ForEach(Array(ranked.enumerated()), id: \.element.0.id) { idx, pair in
                        let (m, s) = pair

                        // Section Headers
                        if !onlyNeedsYou && (idx == 0 || (ranked[idx - 1].1.urgency >= 55 && s.urgency < 55)) {
                            HStack {
                                Text(s.urgency >= 55 ? "NEEDS YOU" : "INFORMATIONAL & AUTOMATED")
                                    .font(.caption2.weight(.bold))
                                    .kerning(1.2)
                                    .foregroundStyle(s.urgency >= 55 ? Color.aetherMagenta : .secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, idx == 0 ? 4 : 16)
                        }

                        ZStack {
                            NavigationLink { ReadingView(message: m) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    UrgencyDial(value: s.urgency)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(m.from.first?.shortLabel ?? "unknown")
                                                .font(.subheadline.weight(.semibold))
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            if let d = m.date {
                                                Text(d, style: .relative)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                            .font(.footnote.weight(m.isUnread ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if let summary = store.summary(for: m.id) {
                                            Text(summary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }

                                        HStack(spacing: 6) {
                                            Label(s.category.rawValue, systemImage: s.category.icon)
                                                .font(.system(size: 10, weight: .semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                                .foregroundStyle(.secondary)

                                            if !s.reason.isEmpty {
                                                Text("·  \(s.reason)")
                                                    .font(.caption2)
                                                    .foregroundStyle(Color.aetherViolet)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .padding(.top, 2)
                                    }
                                    Spacer(minLength: 0)

                                    if m.isUnread {
                                        Circle().fill(Color.aetherMagenta)
                                            .frame(width: 8, height: 8)
                                            .padding(.top, 6)
                                    }
                                }
                                .padding(12)
                                .glassCard(16)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .messageActions(m, store: store)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }
}

/// An interactive, color-coded urgency dial.
struct UrgencyDial: View {
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
            Text("\(value)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 36, height: 36)
    }
}
