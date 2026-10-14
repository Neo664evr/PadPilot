import Foundation

/// One persistent local conversation. No network or account required.
struct LocalConversation: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var messages: [LocalChat]
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    init(title: String = "New conversation", messages: [LocalChat] = []) {
        self.id = UUID()
        self.title = title
        self.messages = messages
        self.createdAt = Date()
        self.updatedAt = Date()
        self.pinned = false
    }

    var preview: String {
        messages.last(where: { $0.role == "user" || !$0.text.isEmpty })?.text
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(105)
            .description ?? "No messages yet"
    }

    var exportedText: String {
        let body = messages.map {
            ($0.role == "user" ? "You" : "LocalLens") + ":\n" + $0.text
        }.joined(separator: "\n\n")
        return "# \(title)\n\n\(body)"
    }
}
