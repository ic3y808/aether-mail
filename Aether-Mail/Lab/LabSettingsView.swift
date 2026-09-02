import SwiftUI
import EmailKit

/// Settings for the experiments.
///
/// These controls started out scattered across the views that used them - the
/// model picker inside Drafts, the text warm-up in the header - which meant a
/// setting was only reachable from whichever screen happened to host it. They
/// belong together, and nothing here touches the shipping app.
struct LabSettingsView: View {
    @Environment(MailStore.self) private var store
    @State private var inference = LabInference.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                demoSection
                modelSection
                contentSection
                dataSection
            }
            .scrollContentBackground(.hidden)
            .background { AuroraBackdrop(intensity: 0.6) }
            .navigationTitle("Lab Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Demo

    private var demoSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.demoMode },
                set: { store.demoMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Demo mode", systemImage: "record.circle")
                        .font(.callout)
                    Text(store.demoMode
                         ? "Showing fabricated mail everywhere. Syncing is paused."
                         : "Fills the whole app with fabricated mail for recording.")
                        .font(.caption2)
                        .foregroundStyle(store.demoMode ? Color.orange : .secondary)
                }
            }
            .tint(Color.aetherViolet)
            .listRowBackground(Color.white.opacity(0.05))

            // Recording before the summaries exist means filming the app think.
            if let prep = store.demoPrep {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Preparing…", systemImage: "hourglass")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(prep.secondsLeft > 0 ? "about \(prep.secondsLeft)s left" : "finishing")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(prep.done), total: Double(max(prep.total, 1)))
                        .tint(Color.aetherViolet)
                    Text("\(prep.done) of \(prep.total) summaries written on device")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.05))
            } else if store.demoMode && store.demoReady {
                Label("Ready to record", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .listRowBackground(Color.white.opacity(0.05))
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Turns off by itself the next time the app launches from cold, so a demo left on cannot quietly hide real mail. Switching to another app and back keeps it on, which is what screen recording needs. While it is on nothing syncs and no notifications fire.")
                .font(.caption2)
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { inference.allowNetworkModels },
                set: { inference.allowNetworkModels = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Use models on your network", systemImage: "network")
                        .font(.callout)
                    Text(inference.allowNetworkModels
                         ? "Message text is sent to the machine you pick."
                         : "Off — nothing leaves this iPhone.")
                        .font(.caption2)
                        .foregroundStyle(inference.allowNetworkModels ? Color.orange : .secondary)
                }
            }
            .tint(Color.aetherViolet)
            .listRowBackground(Color.white.opacity(0.05))

            row(title: "This iPhone",
                subtitle: MailAI.isAvailable ? "on-device · ~3B · always available, never leaves the phone"
                                             : "unavailable on this device",
                active: inference.selected == nil) {
                inference.selected = nil
            }

            if inference.allowNetworkModels {
                ForEach(inference.hosts) { host in
                    row(title: host.best ?? host.engine,
                        subtitle: "\(host.engine) · \(host.address) · only on this Wi-Fi",
                        active: inference.selected?.id == host.id) {
                        inference.selected = host
                    }
                }

                Button {
                    Task { await inference.scan() }
                } label: {
                    HStack {
                        Label(inference.isScanning ? "Scanning this network…" : "Find a bigger model",
                              systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if inference.isScanning { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(inference.isScanning)
                .listRowBackground(Color.white.opacity(0.05))
            }
        } header: {
            Text("Model")
        } footer: {
            Text(!inference.allowNetworkModels
                 ? "Aether Mail is isolated by default: your mail goes to your providers and the AI runs on this iPhone. Nothing is scanned, nothing is sent, and nothing is reported anywhere. Turn this on only if you want to use a machine of your own on this network."
                 : inference.hosts.isEmpty
                   ? "Will look for Ollama (11434) and LM Studio (1234) on your Wi-Fi. A 3B model on the phone invents facts under pressure; a 26B one on a Mac does not."
                   : "Reachable on this network only. Off Wi-Fi the phone answers for itself.")
                .font(.caption2)
        }
    }

    // MARK: Content

    private var contentSection: some View {
        Section {
            Button {
                store.warmAllBodies()
            } label: {
                HStack {
                    Label("Download full text", systemImage: "arrow.down.doc")
                    Spacer()
                    if let p = store.bodyWarmProgress {
                        Text("\(p.done)/\(p.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.aetherViolet)
                    }
                }
            }
            .disabled(store.bodyWarmProgress != nil)
            .listRowBackground(Color.white.opacity(0.05))

            if let summary = store.lastWarmSummary {
                Text(summary)
                    .font(.caption2).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        } header: {
            Text("Content")
        } footer: {
            Text("Extraction and drafting can only use text that has been downloaded. Without this the Lab sees subject lines and nothing else — which is why searching a mailbox for amounts found one instead of dozens.")
                .font(.caption2)
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section("What the Lab can see") {
            stat("Messages", "\(store.inbox.count)")
            stat("With full text", "\(store.openBodies.count)")
            stat("AI summaries", "\(store.summaries.count)")
            if !store.bodyErrors.isEmpty {
                stat("Failed to load", "\(store.bodyErrors.count)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

    private func row(title: String, subtitle: String, active: Bool,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? AnyShapeStyle(LinearGradient.aether) : AnyShapeStyle(Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(active ? .semibold : .regular)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.05))
    }
}
