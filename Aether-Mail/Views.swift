import SwiftUI
import EmailKit

// MARK: - Root

struct RootView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.accounts.isEmpty {
                OnboardingView()
            } else {
                NavigationStack {
                    InboxView()
                        .navigationTitle("All Inboxes")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                NavigationLink { AccountsView() } label: { Image(systemName: "person.2.circle") }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                if store.isSyncing { ProgressView() }
                                else { Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") } }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $store.isAddingAccount) { AddMailboxView() }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                Text(banner)
                    .font(.footnote).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .onTapGesture { store.banner = nil }
                    .task { try? await Task.sleep(for: .seconds(5)); store.banner = nil }
            }
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.gradient).frame(width: 96, height: 96)
                Image(systemName: "envelope.fill").font(.system(size: 42)).foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text("Aether Mail").font(.largeTitle).bold()
                Text("Private, AI-native email — your mail talks straight to your providers, and the AI stays on your devices.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button { store.isAddingAccount = true } label: {
                Text("Add your first mailbox").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 24)
            Text("iCloud, Gmail, Outlook, or any IMAP server. Use an app-specific password.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.bottom, 24)
        }
    }
}

// MARK: - Add mailbox

struct AddMailboxView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var provider: MailProvider = .icloud
    @State private var email = ""
    @State private var password = ""
    @State private var customHost = ""
    @State private var working = false
    @State private var error: String?

    /// Proton needs the local Bridge (a Mac), so it's not offered on iOS.
    private let providers: [MailProvider] = [.icloud, .gmail, .outlook, .custom]

    /// Gmail/Outlook use OAuth when this build has the client IDs configured.
    private var usesOAuth: Bool {
        (provider == .gmail && OAuthClients.hasGoogle) || (provider == .outlook && OAuthClients.hasMicrosoft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach(providers) { p in Text(p.displayName).tag(p) }
                    }
                    if provider == .custom {
                        TextField("IMAP host (imap.example.com)", text: $customHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section(usesOAuth ? "Your email" : "Sign in") {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !usesOAuth {
                        SecureField("App-specific password", text: $password)
                            .textContentType(.password)   // surfaces iCloud Keychain autofill
                    }
                }
                if usesOAuth {
                    Section {
                        Button { oauthSignIn() } label: {
                            HStack {
                                Image(systemName: provider == .gmail ? "g.circle.fill" : "m.circle.fill")
                                Text("Sign in with \(provider == .gmail ? "Google" : "Microsoft")")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || email.isEmpty)
                    } footer: {
                        Text("Opens a secure \(provider.displayName) sign-in sheet — no password is stored.")
                    }
                } else if provider == .gmail || provider == .outlook {
                    Section {
                        Text("These need an **app-specific password** (with 2-factor on). OAuth sign-in isn't configured in this build.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Text(error).font(.callout).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() }
                    else if !usesOAuth {
                        Button("Connect") { passwordConnect() }
                            .disabled(email.isEmpty || password.isEmpty)
                    }
                }
            }
        }
    }

    private func passwordConnect() {
        error = nil; working = true
        Task {
            let r = await store.addAccount(provider: provider, email: email, password: password, customHost: customHost)
            working = false
            if let r { error = r } else { dismiss() }
        }
    }
    private func oauthSignIn() {
        error = nil; working = true
        Task {
            let r = await store.addOAuthAccount(provider: provider, email: email)
            working = false
            if let r { error = r } else { dismiss() }
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        List {
            if store.unreadCount > 0 {
                Section { EmptyView() } header: {
                    Text("\(store.unreadCount) unread").textCase(nil)
                }
            }
            ForEach(store.inbox) { m in
                NavigationLink { ReadingView(message: m) } label: { MessageRow(message: m) }
            }
        }
        .listStyle(.plain)
        .refreshable { await refreshAsync() }
        .overlay {
            if store.inbox.isEmpty && !store.isSyncing {
                ContentUnavailableView("Inbox empty", systemImage: "tray",
                                       description: Text("Pull to refresh, or add another mailbox."))
            }
        }
    }

    private func refreshAsync() async {
        store.refresh()
        // let the spinner show briefly
        try? await Task.sleep(for: .milliseconds(400))
    }
}

struct MessageRow: View {
    @Environment(MailStore.self) private var store
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(.tint.opacity(0.18)).frame(width: 42, height: 42)
                .overlay(Text(initials).font(.headline).foregroundStyle(.tint))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.from.first?.shortLabel ?? "Unknown")
                        .fontWeight(store.isUnread(message) ? .bold : .semibold)
                    Spacer()
                    if let d = message.date {
                        Text(d.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(store.isUnread(message) ? .primary : .secondary)
                if !message.snippet.isEmpty {
                    Text(message.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if store.isUnread(message) {
                Circle().fill(.tint).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        String((message.from.first?.shortLabel ?? "?").prefix(1)).uppercased()
    }
}

// MARK: - Reading

struct ReadingView: View {
    @Environment(MailStore.self) private var store
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
                bodyView
                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.open(message) }
    }

    @ViewBuilder private var bodyView: some View {
        if let body = store.body(for: message) {
            Text(body.bestText.isEmpty ? message.snippet : body.bestText)
                .font(.body).textSelection(.enabled)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Accounts

struct AccountsView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        List {
            Section("Mailboxes") {
                ForEach(store.accounts) { a in
                    HStack {
                        Image(systemName: "envelope.circle.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(a.emailAddress)
                            Text(a.provider.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(store.messagesByAccount[a.id]?.count ?? 0)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in idx.map { store.accounts[$0] }.forEach(store.removeAccount) }
            }
            Section {
                Button { store.isAddingAccount = true } label: {
                    Label("Add another mailbox", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Accounts")
        .toolbar { EditButton() }
    }
}
