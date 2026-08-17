import SwiftUI
import EmailKit

/// Root navigation. iPhone gets a stack (list → reading); iPad naturally widens
/// the same NavigationStack. A split view + Copilot tab come with the AI work.
struct RootView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            InboxView()
                .navigationTitle("All Inboxes")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if store.unreadCount > 0 {
                            Text("\(store.unreadCount) unread").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.isAddingAccount = true } label: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                    }
                }
                .sheet(isPresented: $store.isAddingAccount) { AddMailboxView() }
        }
    }
}

struct InboxView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        List(store.inbox) { m in
            NavigationLink {
                ReadingView(message: m).onAppear { store.markRead(m) }
            } label: {
                MessageRow(message: m)
            }
        }
        .listStyle(.plain)
    }
}

struct MessageRow: View {
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(.tint.opacity(0.18)).frame(width: 42, height: 42)
                .overlay(Text(initials).font(.headline).foregroundStyle(.tint))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.from.first?.shortLabel ?? "Unknown")
                        .fontWeight(message.isUnread ? .bold : .semibold)
                    Spacer()
                    if let d = message.date {
                        Text(d.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(message.isUnread ? .primary : .secondary)
                Text(message.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if message.isUnread {
                Circle().fill(.tint).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        String((message.from.first?.shortLabel ?? "?").prefix(1)).uppercased()
    }
}

struct ReadingView: View {
    let message: MailMessage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.title2).bold()
                HStack(spacing: 12) {
                    Circle().fill(.tint.opacity(0.18)).frame(width: 40, height: 40)
                        .overlay(Text(String((message.from.first?.shortLabel ?? "?").prefix(1)).uppercased())
                            .font(.headline).foregroundStyle(.tint))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.from.first?.shortLabel ?? "Unknown").fontWeight(.medium)
                        if let a = message.from.first?.address {
                            Text(a).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let d = message.date {
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                // Milestone 2: fetch + render the full MIME body here.
                Text(message.snippet).font(.body)
                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddMailboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var provider: MailProvider = .icloud

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Provider", selection: $provider) {
                        ForEach(MailProvider.allCases) { p in
                            Text(p.rawValue.capitalized).tag(p)
                        }
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("App-specific password", text: $password)
                }
                Section {
                    Text("The mail engine (EmailKit) is already shared with the Mac app. Live IMAP sign-in is the next milestone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { dismiss() }
                        .disabled(email.isEmpty || password.isEmpty)
                }
            }
        }
    }
}
