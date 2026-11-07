import SwiftUI
import EmailKit

/// Shelves: Mail organized into horizontal semantic shelves by what each message IS,
/// rather than just chronological arrival order.
struct ShelvesView: View {
    @Environment(MailStore.self) private var store
    @State private var selectedCategory: MailCategory? = nil

    private var items: [MailMessage] { store.inbox }

    private var shelves: [(MailCategory, [MailMessage])] {
        MailCategory.allCases.compactMap { cat in
            let group = items.filter { store.signal(for: $0).category == cat }
                .sorted { store.signal(for: $0).urgency > store.signal(for: $1).urgency }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                // Category jump pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelves, id: \.0) { cat, group in
                            let unread = group.filter { store.isUnread($0) }.count
                            Button {
                                withAnimation(.snappy) {
                                    selectedCategory = (selectedCategory == cat ? nil : cat)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: cat.icon)
                                    Text(cat.rawValue)
                                    if unread > 0 {
                                        Text("\(unread)")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.aetherMagenta))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background {
                                    if selectedCategory == cat {
                                        Capsule().fill(LinearGradient.aether)
                                    } else {
                                        Capsule().fill(.ultraThinMaterial)
                                    }
                                }
                                .foregroundStyle(selectedCategory == cat ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 8)

                if shelves.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 40))
                            .foregroundStyle(LinearGradient.aether)
                            .padding(.top, 24)
                        Text("No Categorized Mail")
                            .font(.headline)
                        Text("As messages arrive, they will be organized into semantic shelves here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    let activeShelves = selectedCategory == nil ? shelves : shelves.filter { $0.0 == selectedCategory }
                    ForEach(activeShelves, id: \.0) { cat, group in
                        shelfRow(category: cat, messages: group)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func shelfRow(category: MailCategory, messages: [MailMessage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Shelf Header
            HStack(spacing: 8) {
                Label(category.rawValue, systemImage: category.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Text("\(messages.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.ultraThinMaterial))

                let unread = messages.filter { store.isUnread($0) }.count
                if unread > 0 {
                    Text("\(unread) new")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.aetherMagenta)
                }

                Spacer()
            }
            .padding(.horizontal, 16)

            // Horizontal Shelf Cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(messages, id: \.id) { m in
                        let facts = store.facts(for: m)
                        let isUnread = store.isUnread(m)

                        NavigationLink { ReadingView(message: m) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(m.from.first?.shortLabel ?? "unknown")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if isUnread {
                                        Circle().fill(Color.aetherMagenta)
                                            .frame(width: 7, height: 7)
                                    }
                                }

                                Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                                    .font(.footnote.weight(isUnread ? .semibold : .regular))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)

                                Spacer(minLength: 0)

                                // Lifted facts chip (e.g. price, tracking code, OTP)
                                if let firstFact = facts.first {
                                    HStack(spacing: 4) {
                                        Image(systemName: firstFact.kind.icon)
                                        Text(firstFact.value)
                                    }
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.cyan.opacity(0.18)))
                                    .foregroundStyle(Color.cyan)
                                    .lineLimit(1)
                                } else if let d = m.date {
                                    Text(d, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(width: 196, height: 126, alignment: .topLeading)
                            .glassCard(16)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            MessageMenu(message: m, store: store)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
