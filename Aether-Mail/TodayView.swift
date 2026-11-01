import SwiftUI
import EmailKit

/// Today: The whole mailbox transformed into an intelligent, zero-latency briefing.
/// Answers "what do I need to know and do right now" without digging through threads.
struct TodayView: View {
    @Environment(MailStore.self) private var store
    @State private var copiedCode: String?

    private var items: [MailMessage] { store.inbox }

    private var needsYou: [MailMessage] {
        items.filter { store.signal(for: $0).urgency >= 55 }
            .sorted { store.signal(for: $0).urgency > store.signal(for: $1).urgency }
    }

    private var awaiting: [MailMessage] {
        items.filter { store.signal(for: $0).needsReply }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var allFacts: [MailExtract.Fact] {
        items.flatMap { store.facts(for: $0) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var codes: [MailExtract.Fact] {
        allFacts.filter { $0.kind == .code }
    }

    private var trackings: [MailExtract.Fact] {
        allFacts.filter { $0.kind == .tracking }
    }

    private var deadlines: [MailExtract.Fact] {
        allFacts.filter { $0.kind == .deadline }
    }

    private var handledCount: Int {
        items.filter { !store.isUnread($0) }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                // Header Briefing
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(), format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                // 4-Stat Metric Row
                HStack(spacing: 8) {
                    stat("\(needsYou.count)", "need you", .aetherMagenta)
                    stat("\(awaiting.count)", "awaiting", .aetherViolet)
                    stat("\(deadlines.count + trackings.count)", "actions", .cyan)
                    stat("\(handledCount)", "handled", .secondary)
                }
                .padding(.horizontal, 14)

                // High Priority Actionable: 2FA / One-Time Passcodes
                if let codeFact = codes.first {
                    otpCard(codeFact)
                }

                // High Priority Actionable: Delivery / Package Tracking
                if let trackFact = trackings.first {
                    trackingCard(trackFact)
                }

                // Deadlines & Dates Mentioned
                if !deadlines.isEmpty {
                    block("Dates & Deadlines", "clock.badge.exclamationmark") {
                        VStack(spacing: 8) {
                            ForEach(deadlines.prefix(3)) { f in
                                HStack {
                                    Image(systemName: "calendar")
                                        .foregroundStyle(Color.cyan)
                                        .font(.caption)
                                    Text(f.value)
                                        .font(.footnote.weight(.medium))
                                    Spacer()
                                    Text(f.sender)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                // Worth Your Attention (Needs You)
                if !needsYou.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Worth Your Attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.aetherMagenta)
                            .padding(.horizontal, 16)

                        ForEach(needsYou.prefix(5)) { m in
                            let sig = store.signal(for: m)
                            ZStack {
                                NavigationLink { ReadingView(message: m) } label: {
                                    HStack(spacing: 12) {
                                        UrgencyDial(value: sig.urgency)
                                        VStack(alignment: .leading, spacing: 3) {
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
                                                .font(.footnote)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(sig.reason)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(Color.aetherViolet)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
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

                // Awaiting Your Reply
                if !awaiting.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Waiting on You", systemImage: "arrow.uturn.left.circle.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.aetherViolet)
                            .padding(.horizontal, 16)

                        ForEach(awaiting.prefix(4)) { m in
                            ZStack {
                                NavigationLink { ReadingView(message: m) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "person.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(Color.aetherViolet)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.from.first?.shortLabel ?? "unknown")
                                                .font(.subheadline.weight(.semibold))
                                                .lineLimit(1)
                                            Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        if let d = m.date {
                                            Text(d, style: .relative)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
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

                // All caught up empty state
                if needsYou.isEmpty && awaiting.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(LinearGradient.aether)
                            .padding(.top, 16)
                        Text("You're all caught up")
                            .font(.headline.weight(.semibold))
                        Text("No urgent items or unanswered questions in your inbox.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .glassCard(20)
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var headline: String {
        if needsYou.isEmpty && awaiting.isEmpty {
            return "Nothing needs you right now."
        }
        if needsYou.isEmpty {
            return "\(awaiting.count) people are waiting on a reply."
        }
        if awaiting.isEmpty {
            return "\(needsYou.count) items need your attention."
        }
        return "\(needsYou.count) things need you, and \(awaiting.count) people are waiting."
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassCard(14)
    }

    @ViewBuilder
    private func block<C: View>(_ title: String, _ icon: String,
                                @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.cyan)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(16)
        .padding(.horizontal, 14)
    }

    private func otpCard(_ f: MailExtract.Fact) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.aetherMagenta.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "key.fill")
                    .font(.title3)
                    .foregroundStyle(Color.aetherMagenta)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Verification Code")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.aetherMagenta)
                    Text("· \(f.sender)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(f.value)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .kerning(2)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = f.value
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.snappy) { copiedCode = f.value }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if copiedCode == f.value { withAnimation { copiedCode = nil } }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedCode == f.value ? "checkmark" : "doc.on.doc")
                    Text(copiedCode == f.value ? "Copied" : "Copy")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(copiedCode == f.value ? Color.green.opacity(0.2) : Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(copiedCode == f.value ? Color.green : Color.white.opacity(0.2)))
                .foregroundStyle(copiedCode == f.value ? .green : .primary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassCard(18)
        .padding(.horizontal, 14)
    }

    private func trackingCard(_ f: MailExtract.Fact) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "shippingbox.fill")
                    .font(.title3)
                    .foregroundStyle(Color.cyan)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Package Tracking")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.cyan)
                    Text("· \(f.sender)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(f.value)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = f.value
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassCard(18)
        .padding(.horizontal, 14)
    }
}
