import SwiftUI
import EmailKit

/// The message actions, in the shapes a phone expects: swipe on the row for the
/// two things you do constantly, long-press for everything else. The macOS
/// client puts the same set in a menu bar and a right-click menu; on iOS the
/// gestures *are* the interface, so the row carries them and nothing is buried
/// behind a screen you have to open first.
extension View {
    func messageActions(_ message: MailMessage, store: MailStore) -> some View {
        modifier(MessageActions(message: message, store: store))
    }
}

private struct MessageActions: ViewModifier {
    let message: MailMessage
    let store: MailStore

    private var isPermanent: Bool { store.deleteIntent(for: [message]) == .permanent }
    private var isUnread: Bool { store.isUnread(message) }
    private var isFlagged: Bool { message.flags.contains(.flagged) }

    func body(content: Content) -> some View {
        content
            // Trailing edge: destructive. Full swipe deletes, because that is the
            // gesture people already have in their fingers from Mail.
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    store.requestDelete([message])
                } label: {
                    Label(isPermanent ? "Delete" : "Trash",
                          systemImage: isPermanent ? "trash.slash" : "trash")
                }
                Button {
                    store.archive([message])
                } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(.indigo)
            }
            // Leading edge: the non-destructive pair.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    store.setRead(message, isUnread)
                } label: {
                    Label(isUnread ? "Read" : "Unread",
                          systemImage: isUnread ? "envelope.open" : "envelope.badge")
                }
                .tint(.blue)
                Button {
                    store.toggleFlagged(message)
                } label: {
                    Label(isFlagged ? "Unflag" : "Flag",
                          systemImage: isFlagged ? "flag.slash" : "flag")
                }
                .tint(.orange)
            }
            .contextMenu { MessageMenu(message: message, store: store) }
    }
}

/// Shared by the row long-press and the reading view's ••• button so the two can
/// never drift apart.
struct MessageMenu: View {
    let message: MailMessage
    let store: MailStore

    var body: some View {
        Button(store.isUnread(message) ? "Mark as Read" : "Mark as Unread",
               systemImage: store.isUnread(message) ? "envelope.open" : "envelope.badge") {
            store.setRead(message, store.isUnread(message))
        }
        Button(message.flags.contains(.flagged) ? "Remove Flag" : "Flag",
               systemImage: message.flags.contains(.flagged) ? "flag.slash" : "flag") {
            store.toggleFlagged(message)
        }

        Divider()

        Button("Archive", systemImage: "archivebox") { store.archive([message]) }
        Button("Mark as Junk", systemImage: "xmark.bin") { store.markAsJunk([message]) }

        let destinations = store.moveDestinations(for: message)
        if !destinations.isEmpty {
            Menu("Move to", systemImage: "folder") {
                ForEach(destinations) { folder in
                    Button(folder.displayName, systemImage: folder.role.icon) {
                        store.move(message, toPath: folder.path)
                    }
                }
            }
        }

        Divider()

        if store.deleteIntent(for: [message]) == .permanent {
            Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                store.requestDelete([message])
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                store.requestDelete([message])
            }
            Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                store.pendingDelete = [message]
            }
        }
    }
}

/// Confirmation for the irreversible delete, plus the undo toast for the ones
/// that aren't. Applied once at the root so every list and the reading view get
/// them without each re-implementing the presentation.
struct MessageActionChrome: ViewModifier {
    @Environment(MailStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        return content
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(
                    get: { store.pendingDelete != nil },
                    set: { if !$0 { store.pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) { store.confirmPendingDelete() }
                Button("Cancel", role: .cancel) { store.pendingDelete = nil }
            } message: {
                Text("This can't be undone.")
            }
            .overlay(alignment: .bottom) { undoToast }
    }

    private var deleteTitle: String {
        let count = store.pendingDelete?.count ?? 0
        return count == 1 ? "Delete this message permanently?"
                          : "Delete \(count) messages permanently?"
    }

    @ViewBuilder
    private var undoToast: some View {
        if let undo = store.undoAction {
            HStack(spacing: 14) {
                Text(undo.summary).font(.subheadline.weight(.medium))
                Button("Undo") { undo.revert() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .padding(.bottom, 28)
            .shadow(radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(undo.id)
            .task(id: undo.id) {
                // Long enough to notice and reach, short enough not to sit on the
                // list. Matches the macOS client's undo, which lives in a toolbar
                // button rather than a timed toast.
                try? await Task.sleep(for: .seconds(6))
                if store.undoAction?.id == undo.id { store.undoAction = nil }
            }
        }
    }
}

extension View {
    func messageActionChrome() -> some View { modifier(MessageActionChrome()) }
}
