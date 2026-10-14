import SwiftUI

/// A dedicated conversation library. Chats remain entirely on the device.
struct ChatsLibraryView: View {
    @ObservedObject var runtime: LocalRuntime
    let accent: Color
    let onOpen: () -> Void

    @State private var query = ""
    @State private var renameTarget: UUID?
    @State private var renameText = ""
    @State private var renameOpen = false
    @State private var deleteTarget: UUID?
    @State private var deleteOpen = false

    private var filtered: [LocalConversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return runtime.sortedConversations }
        return runtime.sortedConversations.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(q) })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your chats")
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("\(runtime.conversations.count) conversations • saved offline")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        runtime.newConversation()
                        onOpen()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .frame(width: 46, height: 46)
                            .background(accent, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .disabled(runtime.generating || runtime.loading)
                    .accessibilityLabel("New chat")
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversations", text: $query)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(15)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17))

                if !runtime.conversationNotice.isEmpty {
                    Label(runtime.conversationNotice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("No matching conversations")
                            .font(.headline)
                        Text("Try another keyword or start a new chat.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 75)
                } else {
                    if filtered.contains(where: { $0.pinned }) {
                        sectionTitle("PINNED", systemImage: "pin.fill")
                        ForEach(filtered.filter { $0.pinned }) { thread in
                            threadRow(thread)
                        }
                    }
                    sectionTitle("RECENT", systemImage: "clock")
                    ForEach(filtered.filter { !$0.pinned }) { thread in
                        threadRow(thread)
                    }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("Rename conversation", isPresented: $renameOpen) {
            TextField("Chat title", text: $renameText)
            Button("Save") {
                if let id = renameTarget { runtime.renameConversation(id, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Choose a name you'll recognize later.")
        }
        .confirmationDialog("Delete this chat?", isPresented: $deleteOpen,
                            titleVisibility: .visible) {
            Button("Delete conversation", role: .destructive) {
                if let id = deleteTarget { runtime.removeConversation(id) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This removes the saved messages from this iPhone.")
        }
    }

    private func sectionTitle(_ label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.3)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
    }

    private func threadRow(_ chat: LocalConversation) -> some View {
        HStack(spacing: 10) {
            Button {
                runtime.openConversation(chat.id)
                onOpen()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: chat.pinned ? "pin.circle.fill" : "bubble.left.and.text.bubble.right")
                        .font(.system(size: 21))
                        .foregroundStyle(accent)
                        .frame(width: 33)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chat.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(chat.preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(chat.updatedAt, style: .relative)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if chat.id == runtime.activeConversationID {
                        Circle().fill(accent).frame(width: 7, height: 7)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(runtime.generating || runtime.loading)

            Menu {
                Button {
                    renameTarget = chat.id
                    renameText = chat.title
                    renameOpen = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button {
                    runtime.togglePin(chat.id)
                } label: {
                    Label(chat.pinned ? "Unpin" : "Pin chat",
                          systemImage: chat.pinned ? "pin.slash" : "pin")
                }
                ShareLink(item: chat.exportedText) {
                    Label("Share transcript", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    deleteTarget = chat.id
                    deleteOpen = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(runtime.generating || runtime.loading)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 46)
            }
            .accessibilityLabel("More options for \(chat.title)")
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .strokeBorder(chat.id == runtime.activeConversationID ?
                              accent.opacity(0.36) : Color.white.opacity(0.055), lineWidth: 1)
        }
    }
}
