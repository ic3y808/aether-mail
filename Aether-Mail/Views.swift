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
                        .background { AuroraBackdrop() }
                        .navigationTitle("All Inboxes")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                NavigationLink { MailboxesView() } label: { Image(systemName: "tray.2") }
                            }
                            ToolbarItem(placement: .topBarLeading) {
                                NavigationLink { AccountsView() } label: { Image(systemName: "person.2.circle") }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                if store.isSyncing { ProgressView() }
                                else { Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") } }
                            }
                        }
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
            }
        }
        .sheet(isPresented: $store.isAddingAccount) { AddMailboxView() }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                Text(banner)
                    .font(.footnote).padding(12).glassCard(14).padding()
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
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 22) {
                Spacer()
                GlowOrb(systemImage: "envelope.fill", size: 96)
                VStack(spacing: 8) {
                    Text("Aether Mail").font(.largeTitle).bold()
                    Text("Private, AI-native email — your mail talks straight to your providers, and the AI runs right on your device.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                Button { store.isAddingAccount = true } label: {
                    Text("Add your first mailbox").fontWeight(.semibold).frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 24)
                Text("iCloud, Gmail, Outlook, or any IMAP server.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        List {
            ForEach(store.accounts.filter { store.syncState[$0.id]?.errorText != nil }) { account in
                SyncErrorRow(account: account)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            }
            if store.aiAvailable {
                Label("On-device AI ready — summaries run on your iPhone", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(store.inbox) { m in
                ZStack {
                    MessageRow(message: m).padding(12).glassCard(16)
                    NavigationLink { ReadingView(message: m) } label: { EmptyView() }.opacity(0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { store.refresh(); try? await Task.sleep(for: .milliseconds(500)) }
        .overlay {
            if store.inbox.isEmpty && !store.isSyncing && !store.hasSyncErrors {
                ContentUnavailableView("Inbox empty", systemImage: "tray",
                                       description: Text("Pull to refresh, or add another mailbox."))
            }
        }
    }
}

/// A tappable red strip explaining why an account didn't sync — so a failure is
/// visible and retryable instead of a banner that vanishes after five seconds.
struct SyncErrorRow: View {
    @Environment(MailStore.self) private var store
    let account: MailAccount

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.emailAddress).font(.subheadline).fontWeight(.semibold)
                Text(store.syncState[account.id]?.errorText ?? "Couldn't sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Retry") { Task { await store.sync(account) } }
                .font(.caption).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.orange.opacity(0.35)))
    }
}

struct MessageRow: View {
    @Environment(MailStore.self) private var store
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient.aether.opacity(0.9))
                Text(initials).font(.headline).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
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
                Circle().fill(LinearGradient.aether).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
    }

    private var initials: String {
        String((message.from.first?.shortLabel ?? "?").prefix(1)).uppercased()
    }
}

// MARK: - Reading

struct ReadingView: View {
    @Environment(MailStore.self) private var store
    let message: MailMessage
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if store.aiAvailable { aiSummary }
                bodyCard
                askBox
                Spacer(minLength: 30)
            }
            .padding()
        }
        .background { AuroraBackdrop(intensity: 0.7) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { store.open(message) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.subject.isEmpty ? "(no subject)" : message.subject).font(.title3).bold()
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient.aether.opacity(0.9))
                    Text(String((message.from.first?.shortLabel ?? "?").prefix(1)).uppercased())
                        .font(.headline).foregroundStyle(.white)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.from.first?.shortLabel ?? "Unknown").fontWeight(.medium)
                    if let a = message.from.first?.address {
                        Text(a).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let d = message.date {
                    Text(d.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14).glassCard(18)
    }

    private var aiSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            GlowOrb(systemImage: "sparkles", size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Summary").font(.caption2).foregroundStyle(.secondary).kerning(1.2)
                if let s = store.summary(for: message.id) {
                    Text(s).font(.callout)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Summarizing on device…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(LinearGradient.aether.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    private var bodyCard: some View {
        Group {
            if let body = store.body(for: message) {
                Text(body.bestText.isEmpty ? message.snippet : body.bestText)
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(16).glassCard(18)
    }

    @ViewBuilder private var askBox: some View {
        if store.aiAvailable {
            VStack(alignment: .leading, spacing: 10) {
                if let answer {
                    Text(answer).font(.callout).textSelection(.enabled)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    TextField("Ask about this email…", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                    if asking { ProgressView().controlSize(.small) }
                    else {
                        Button { ask() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white).frame(width: 30, height: 30)
                                .background(question.isEmpty ? AnyShapeStyle(.gray.opacity(0.4)) : AnyShapeStyle(LinearGradient.aether), in: Circle())
                        }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(10).glassCard(16)
            }
        }
    }

    private func ask() {
        let q = question
        question = ""; asking = true; answer = nil
        Task {
            answer = await store.ask(q, about: message) ?? "On-device AI isn't available right now."
            asking = false
        }
    }
}

// MARK: - Mailboxes (folders)

/// Every account and its IMAP folders, drilling into a folder's messages —
/// the iOS take on the macOS client's mailbox sidebar.
struct MailboxesView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        List {
            ForEach(store.enabledAccounts) { account in
                Section {
                    ForEach(store.foldersByAccount[account.id] ?? []) { folder in
                        NavigationLink {
                            FolderMessagesView(account: account, folder: folder)
                        } label: {
                            Label {
                                Text(folder.role == .inbox ? "Inbox" : folder.displayName)
                            } icon: {
                                Image(systemName: folder.role.icon).foregroundStyle(account.provider.tint)
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                    if store.foldersByAccount[account.id] == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading folders…").font(.caption).foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack(spacing: 8) {
                        ProviderBadge(provider: account.provider, size: 22)
                        Text(account.emailAddress).textCase(nil)
                    }
                }
                .task { await store.loadFolders(account) }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AuroraBackdrop(intensity: 0.6) }
        .navigationTitle("Mailboxes")
    }
}

/// The message list for one account's folder (Sent, Archive, a label, etc.).
struct FolderMessagesView: View {
    @Environment(MailStore.self) private var store
    let account: MailAccount
    let folder: MailFolder

    private var messages: [MailMessage] { store.messages(account.id, folder.path) }

    var body: some View {
        List {
            ForEach(messages) { m in
                ZStack {
                    MessageRow(message: m).padding(12).glassCard(16)
                    NavigationLink { ReadingView(message: m) } label: { EmptyView() }.opacity(0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AuroraBackdrop(intensity: 0.6) }
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView("No messages", systemImage: folder.role.icon,
                                       description: Text("This folder is empty or still loading."))
            }
        }
        .refreshable { await store.syncFolder(account, folder.path) }
        .task { if messages.isEmpty { await store.syncFolder(account, folder.path) } }
        .navigationTitle(folder.role == .inbox ? "Inbox" : folder.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Accounts

struct AccountsView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(store.accounts) { account in
                    AccountCard(account: account)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                }
                .onDelete { idx in idx.map { store.accounts[$0] }.forEach(store.removeAccount) }
            }
            Section {
                Button { store.isAddingAccount = true } label: {
                    Label("Add another mailbox", systemImage: "plus")
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AuroraBackdrop(intensity: 0.6) }
        .navigationTitle("Accounts")
        .toolbar { EditButton() }
    }
}

/// A glass account tile: provider badge, address, provider name, live status,
/// and the inbox count — matching the macOS Courier account rows.
struct AccountCard: View {
    @Environment(MailStore.self) private var store
    let account: MailAccount

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: account.provider, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.emailAddress).fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 6) {
                    Text(account.provider.displayName)
                    statusView
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            let count = store.messagesByAccount[account.id]?.count ?? 0
            if count > 0 {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).glassCard(16)
    }

    @ViewBuilder private var statusView: some View {
        switch store.syncState[account.id] {
        case .syncing:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Syncing…") }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).lineLimit(1)
        case .ok:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            EmptyView()
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

    private let providers: [MailProvider] = [.icloud, .gmail, .outlook, .custom]
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
                        SecureField("App-specific password", text: $password).textContentType(.password)
                    }
                }
                if usesOAuth {
                    Section {
                        Button { oauthSignIn() } label: {
                            HStack {
                                Image(systemName: provider == .gmail ? "g.circle.fill" : "m.circle.fill")
                                Text("Sign in with \(provider == .gmail ? "Google" : "Microsoft")")
                            }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).disabled(working || email.isEmpty)
                    } footer: {
                        Text("Opens a secure \(provider.displayName) sign-in — no password stored.")
                    }
                } else if provider == .gmail || provider == .outlook {
                    Section {
                        Text("These need an **app-specific password** (with 2-factor on). OAuth sign-in isn't configured in this build.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).font(.callout).foregroundStyle(.red) } }
            }
            .navigationTitle("Add Mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() }
                    else if !usesOAuth {
                        Button("Connect") { passwordConnect() }.disabled(email.isEmpty || password.isEmpty)
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
