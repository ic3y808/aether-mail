import SwiftUI

// Compact Aether palette for the watch (Theme.swift lives in the iOS target).
extension Color {
    static let watchViolet  = Color(red: 0.60, green: 0.38, blue: 0.96)
    static let watchMagenta = Color(red: 0.925, green: 0.282, blue: 0.60)
}
extension LinearGradient {
    static let watchAether = LinearGradient(colors: [.watchViolet, .watchMagenta],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct WatchRootView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.mirror.messages.isEmpty {
                    ContentUnavailableView("No mail yet", systemImage: "envelope",
                                           description: Text(store.hasData ? "Inbox is clear." : "Open Aether Mail on your iPhone."))
                } else {
                    List {
                        ForEach(store.mirror.messages) { g in
                            NavigationLink { WatchDetailView(glance: g) } label: { WatchRow(glance: g) }
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white.opacity(0.06)))
                        }
                    }
                    .listStyle(.carousel)
                }
            }
            .navigationTitle("Aether")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.mirror.unreadCount > 0 {
                        Text("\(store.mirror.unreadCount)")
                            .font(.caption2).bold().foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(LinearGradient.watchAether, in: Capsule())
                    }
                }
            }
        }
    }
}

struct WatchRow: View {
    let glance: MailGlance
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if glance.unread {
                    Circle().fill(LinearGradient.watchAether).frame(width: 7, height: 7)
                }
                Text(glance.sender).font(.headline).lineLimit(1)
            }
            Text(glance.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let s = glance.summary {
                Label(s, systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(Color.watchViolet).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct WatchDetailView: View {
    let glance: MailGlance
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(glance.subject).font(.headline)
                Text(glance.sender).font(.caption).foregroundStyle(.secondary)
                if let s = glance.summary {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(LinearGradient.watchAether)
                        Text(s).font(.footnote)
                    }
                    .padding(8)
                    .background(LinearGradient.watchAether.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !glance.snippet.isEmpty {
                    Text(glance.snippet).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle(glance.sender)
        .navigationBarTitleDisplayMode(.inline)
    }
}
