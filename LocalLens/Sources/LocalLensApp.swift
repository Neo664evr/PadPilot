import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import Darwin

// LocalLens: a standalone on-device GGUF chat and vision client.
struct LocalChat: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String
    var text: String

    init(role: String, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
}

struct RunSettings {
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let reasoningBudget: Int
    let stopWords: [String]
}

final class LocalRuntime: ObservableObject {
    @Published var messages: [LocalChat] = []
    @Published private(set) var conversations: [LocalConversation] = []
    @Published private(set) var activeConversationID: UUID?
    @Published var conversationNotice = ""

    var activeConversation: LocalConversation? {
        conversations.first(where: { $0.id == activeConversationID })
    }
    var sortedConversations: [LocalConversation] {
        conversations.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }
    private let archiveURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLens-conversations.json")
    }()
    @Published var status = "Select a language model to begin."
    @Published var loading = false
    @Published var generating = false
    @Published var ready = false
    @Published var vision = false
    @Published var lastStats = ""
    @Published var memoryStatus = "Reading memory…"
    @Published var installedRAM = "—"
    @Published var currentAppRAM = "—"
    @Published var remainingAppBudget = "—"
    @Published var memoryLastChecked = "—"

    private let bridge = LlamaBridge()
    private let queue = DispatchQueue(label: "locallens.inference", qos: .userInitiated)
    private var firstTurn = true
    private var gemmaDialect = false
    private var loadedSystemPrompt = ""
    private(set) var loadedModelPath: String?
    private(set) var loadedProjectorPath: String?
    private static let conversationKey = "locallens.v3.messages"

    init() {
        if let data = try? Data(contentsOf: archiveURL),
           let restored = try? JSONDecoder().decode([LocalConversation].self, from: data) {
            conversations = restored
        }
        // Import previous v3 single conversation without deleting it.
        if conversations.isEmpty,
           let data = UserDefaults.standard.data(forKey: Self.conversationKey),
           let previous = try? JSONDecoder().decode([LocalChat].self, from: data),
           !previous.isEmpty {
            var migrated = LocalConversation(title: "Recovered conversation",
                                            messages: previous)
            migrated.updatedAt = Date()
            conversations = [migrated]
            archive()
        }
        if conversations.isEmpty {
            conversations = [LocalConversation()]
        }
        activeConversationID = conversations.sorted(by: { $0.updatedAt > $1.updatedAt }).first?.id
        messages = activeConversation?.messages ?? []
        // Replace incomplete in-flight responses after abnormal termination.
        if let last = messages.last, last.role == "assistant", last.text.isEmpty {
            messages[messages.count - 1].text = "Response interrupted. Try again."
            persist()
        }
        if !messages.isEmpty {
            status = "Conversation restored · Load a model to resume"
        }
        refreshMemoryStatus()
    }

    /// Show real, different measurements instead of calling a process limit "free RAM".
    /// task_info's phys_footprint reflects the running app/container's physical footprint.
    /// os_proc_available_memory is remaining *process* headroom, NOT free device RAM.
    func refreshMemoryStatus() {
        installedRAM = ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)

        var vm = task_vm_info_data_t()
        let words = MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(words)
        let outcome = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if outcome == KERN_SUCCESS {
            currentAppRAM = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: vm.phys_footprint), countStyle: .memory)
        } else {
            currentAppRAM = "Unavailable"
        }

        #if targetEnvironment(simulator)
        remainingAppBudget = "Not applicable to Simulator"
        #else
        let allowance = os_proc_available_memory()
        remainingAppBudget = allowance > 0
            ? "≈" + ByteCountFormatter.string(fromByteCount: Int64(clamping: allowance), countStyle: .memory)
            : "Unavailable"
        #endif

        memoryStatus = "RAM in use: \(currentAppRAM) · additional app allowance: \(remainingAppBudget)"
        memoryLastChecked = Date().formatted(date: .omitted, time: .standard)
    }

    private func archive() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        do {
            try data.write(to: archiveURL, options: .atomic)
            conversationNotice = ""
        } catch {
            conversationNotice = "Could not save chat: \(error.localizedDescription)"
        }
    }

    private func persist() {
        guard let id = activeConversationID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages = messages
        conversations[index].updatedAt = Date()
        if conversations[index].title == "New conversation",
           let question = messages.first(where: { $0.role == "user" })?.text {
            let cleaned = question.replacingOccurrences(of: "📷 ", with: "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                conversations[index].title = String(cleaned.prefix(54))
            }
        }
        archive()
    }

    func newConversation() {
        guard !generating && !loading else { return }
        persist()
        let chat = LocalConversation()
        conversations.insert(chat, at: 0)
        activeConversationID = chat.id
        messages = []
        firstTurn = true
        archive()
        resetInferenceConversation()
    }

    func openConversation(_ id: UUID) {
        guard !generating && !loading, id != activeConversationID else { return }
        persist()
        guard let next = conversations.first(where: { $0.id == id }) else { return }
        activeConversationID = id
        messages = next.messages
        firstTurn = true
        archive()
        resetInferenceConversation()
    }

    func renameConversation(_ id: UUID, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].title = String(cleaned.prefix(80))
        conversations[i].updatedAt = Date()
        archive()
    }

    func togglePin(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned.toggle()
        archive()
    }

    func removeConversation(_ id: UUID) {
        guard !generating && !loading else { return }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [LocalConversation()] }
        if activeConversationID == id {
            let latest = sortedConversations.first!
            activeConversationID = latest.id
            messages = latest.messages
            firstTurn = true
            resetInferenceConversation()
        }
        archive()
    }

    private func resetInferenceConversation() {
        guard ready else { return }
        let sys = gemmaDialect || loadedSystemPrompt.isEmpty
            ? "" : "<|im_start|>system\n\(loadedSystemPrompt)<|im_end|>\n"
        queue.async {
            do {
                try self.bridge.reset(withSystemPrompt: sys)
            } catch {
                DispatchQueue.main.async { self.status = "Conversation reset failed: \(error.localizedDescription)" }
            }
        }
    }

    func load(modelPath: String, projectorPath: String?, context: Int = 4096,
              gpuLayers: Int = 999, systemPrompt: String = "") {
        guard !loading && !generating else { return }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            status = "Model file missing. Import it again."
            return
        }
        if let projectorPath, !FileManager.default.fileExists(atPath: projectorPath) {
            status = "Vision projector file missing."
            return
        }
        #if !targetEnvironment(simulator)
        if projectorPath != nil && os_proc_available_memory() < 1_700 * 1024 * 1024 {
            status = "Not enough free memory to load vision safely. Close other apps or choose smaller weights."
            return
        }
        #endif
        ready = false
        loading = true
        status = "Loading model…"
        let gpu = max(0, min(999, gpuLayers))
        let ctx = max(1024, min(16384, context))
        queue.async {
            self.bridge.unload()
            do {
                try self.bridge.loadModel(atPath: modelPath,
                                          mmprojPath: projectorPath,
                                          nCtx: Int32(ctx),
                                          nGpuLayers: Int32(gpu),
                                          compressionEnabled: true)
                // Gemma has no system role. Embed it with the first user turn.
                let info = self.bridge.modelInfo
                let gemma = info?.chatTemplate.contains("<start_of_turn>") ?? modelPath.lowercased().contains("gemma")
                let prompt = !gemma && !systemPrompt.isEmpty
                    ? "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
                    : ""
                try self.bridge.reset(withSystemPrompt: prompt)
                let hasVision = info?.supportsVision ?? false
                DispatchQueue.main.async {
                    self.loading = false
                    self.ready = true
                    self.vision = hasVision
                    self.gemmaDialect = gemma
                    self.loadedSystemPrompt = systemPrompt
                    self.loadedModelPath = modelPath
                    self.loadedProjectorPath = projectorPath
                    self.firstTurn = true
                    self.lastStats = ""
                    self.status = hasVision ? "Ready · Vision enabled" : "Ready · Text chat"
                    self.refreshMemoryStatus()
                }
            } catch {
                self.bridge.unload()
                DispatchQueue.main.async {
                    self.loading = false
                    self.ready = false
                    self.vision = false
                    self.loadedModelPath = nil
                    self.loadedProjectorPath = nil
                    self.status = "Load failed: \(error.localizedDescription)"
                    self.refreshMemoryStatus()
                }
            }
        }
    }

    func unload() {
        guard !loading && !generating else { return }
        ready = false
        vision = false
        loadedModelPath = nil
        loadedProjectorPath = nil
        status = "Model offloaded."
        queue.async {
            self.bridge.unload()
            DispatchQueue.main.async { self.refreshMemoryStatus() }
        }
    }

    func reset() {
        guard !loading && !generating else { return }
        messages = []
        persist()
        firstTurn = true
        resetInferenceConversation()
    }

    func stop() { bridge.requestStop() }

    @discardableResult
    func send(text: String, imagePath: String?, options: RunSettings,
              systemPrompt: String = "", minimumImageMemoryMB: Int = 1400) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready && !generating && (!question.isEmpty || imagePath != nil) else { return false }
        if let imagePath {
            guard vision else {
                status = "Load your matching vision projector before sending images."
                return false
            }
            guard FileManager.default.fileExists(atPath: imagePath) else {
                status = "Image attachment missing. Select it again."
                return false
            }
            #if !targetEnvironment(simulator)
            let available = os_proc_available_memory()
            if available < UInt64(max(700, minimumImageMemoryMB)) * 1024 * 1024 {
                status = "Image held back to prevent iOS memory termination. Offload and try a smaller GGUF, or close other apps."
                refreshMemoryStatus()
                return false
            }
            #endif
        }

        let answerID = UUID()
        messages.append(LocalChat(role: "user", text: (imagePath == nil ? "" : "📷 ") + question))
        messages.append(LocalChat(id: answerID, role: "assistant", text: ""))
        persist()
        generating = true
        status = imagePath == nil ? "Generating…" : "Analyzing image…"
        let isFirst = firstTurn
        firstTurn = false
        let mediaMarker = imagePath == nil ? "" : LlamaBridge.mediaMarker() + "\n"
        let gemma = gemmaDialect

        // When returning to an archived conversation, replay recent text turns
        // into the freshly reset context. Images from old turns are text labels only.
        let previous = isFirst
            ? Array(messages.dropLast(2).suffix(12))
            : []
        var history = ""
        for item in previous where !item.text.isEmpty {
            let role = item.role == "user" ? "user" : (gemma ? "model" : "assistant")
            let safeText = String(item.text.suffix(3000))
            if gemma {
                history += "<start_of_turn>\(role)\n\(safeText)<end_of_turn>\n"
            } else {
                history += "<|im_start|>\(role)\n\(safeText)<|im_end|>\n"
            }
        }
        // Bound the replay to avoid runaway context allocations.
        history = String(history.suffix(9000))
        let prompt: String
        if gemma {
            let prefix = isFirst ? "" : "<end_of_turn>\n"
            let sys = isFirst && !systemPrompt.isEmpty ? systemPrompt + "\n\n" : ""
            prompt = prefix + history + "<start_of_turn>user\n" + sys + mediaMarker + question +
                     "<end_of_turn>\n<start_of_turn>model\n"
        } else {
            let prefix = isFirst ? "" : "<|im_end|>\n"
            prompt = prefix + history + "<|im_start|>user\n" + mediaMarker + question +
                     "<|im_end|>\n<|im_start|>assistant\n"
        }
        let imagePaths: [String] = imagePath.map { [$0] } ?? []
        queue.async {
            // Refuse risky image decoding while memory is constrained.
            #if !targetEnvironment(simulator)
            if !imagePaths.isEmpty && os_proc_available_memory() < UInt64(max(700, minimumImageMemoryMB)) * 1024 * 1024 {
                DispatchQueue.main.async {
                    self.generating = false
                    self.status = "Image not processed: insufficient free memory."
                    if let i = self.messages.firstIndex(where: { $0.id == answerID }) {
                        self.messages[i].text = "Image processing stopped before encoding to protect the app from a memory crash."
                    }
                    self.persist()
                }
                return
            }
            #endif
            let params = LMGenerationParams.defaults()
            params.maxTokens = Int32(max(32, min(4096, options.maxTokens)))
            params.temperature = max(0, min(2, options.temperature))
            params.topP = max(0.1, min(1, options.topP))
            params.topK = Int32(max(0, min(200, options.topK)))
            params.thinkBudget = Int32(max(0, options.reasoningBudget))
            var stopReached = false
            var accumulated = ""
            let started = Date()
            self.bridge.generate(withPrompt: prompt,
                                 imagePaths: imagePaths,
                                 audioPaths: [],
                                 params: params,
                                 onToken: { piece in
                // Keep token assembly and stop detection on the inference queue.
                // Never mutate callback state from the UI queue.
                guard !stopReached else { return }
                accumulated += piece
                if let stop = options.stopWords.filter({ !$0.isEmpty })
                    .compactMap({ marker -> (Int, String)? in
                        guard let range = accumulated.range(of: marker) else { return nil }
                        return (accumulated.distance(from: accumulated.startIndex, to: range.lowerBound), marker)
                    }).min(by: { $0.0 < $1.0 }) {
                    accumulated = String(accumulated.prefix(stop.0))
                    stopReached = true
                    self.bridge.requestStop()
                }
                let output = accumulated
                DispatchQueue.main.async {
                    if let index = self.messages.firstIndex(where: { $0.id == answerID }) {
                        self.messages[index].text = output
                    }
                }
            }, onDone: { success, message, stats in
                let elapsed = Date().timeIntervalSince(started)
                let finalOutput = accumulated
                DispatchQueue.main.async {
                    if let index = self.messages.firstIndex(where: { $0.id == answerID }) {
                        self.messages[index].text = finalOutput
                    }
                    self.generating = false
                    self.lastStats = (stats ?? "") + String(format: " · %.1fs", elapsed)
                    if !success {
                        self.status = "Generation failed: \(message ?? "Unknown error")"
                        if let i = self.messages.firstIndex(where: { $0.id == answerID }),
                           self.messages[i].text.isEmpty {
                            self.messages[i].text = "⚠️ \(message ?? "Model generation failed.")"
                        }
                    } else {
                        self.status = self.vision ? "Ready · Vision enabled" : "Ready · Text chat"
                    }
                    self.refreshMemoryStatus()
                    self.persist()
                }
            })
        }
        return true
    }
}

extension LocalChat {
    init(id: UUID, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

final class ModelFiles: ObservableObject {
    @Published var weights: [URL] = []
    @Published var projectors: [URL] = []
    @Published var notice = ""

    let directory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let gguf = files.filter { $0.pathExtension.lowercased() == "gguf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        weights = gguf.filter { !$0.lastPathComponent.lowercased().contains("mmproj") }
        projectors = gguf.filter { $0.lastPathComponent.lowercased().contains("mmproj") }
    }

    func deleteFile(_ file: URL) {
        let safe = file.standardizedFileURL.path
        let root = directory.standardizedFileURL.path + "/"
        guard safe.hasPrefix(root), safe.lowercased().hasSuffix(".gguf") else {
            notice = "Cannot delete a file outside the model library."
            return
        }
        do {
            try FileManager.default.removeItem(at: file)
            refresh()
            notice = "Deleted \(file.lastPathComponent)"
        } catch {
            notice = "Delete failed: \(error.localizedDescription)"
        }
    }

    func importFile(_ picked: URL, asProjector: Bool = false) {
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        guard picked.pathExtension.lowercased() == "gguf" else {
            notice = "Only .gguf files are supported."
            return
        }
        let incomingName = picked.lastPathComponent
        let savedName = asProjector && !incomingName.lowercased().contains("mmproj")
            ? "mmproj-" + incomingName
            : incomingName
        var dest = directory.appendingPathComponent(savedName)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            var n = 2
            repeat {
                dest = directory.appendingPathComponent("\(stem)-\(n).gguf")
                n += 1
            } while FileManager.default.fileExists(atPath: dest.path)
        }
        do {
            try FileManager.default.copyItem(at: picked, to: dest)
            refresh()
            notice = "Imported \(dest.lastPathComponent)"
        } catch {
            notice = "Import failed: \(error.localizedDescription)"
        }
    }
}

final class SpeechPlayer: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.49
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

@main
struct LocalLensApp: App {
    var body: some Scene {
        WindowGroup {
            LocalLensView().preferredColorScheme(.dark)
        }
    }
}

private enum ImportRole { case language, vision }

struct LocalLensView: View {
    @StateObject private var files = ModelFiles()
    @StateObject private var runtime = LocalRuntime()
    @State private var selectedLanguage = ""
    @State private var selectedProjector = ""
    @State private var importRole: ImportRole = .language
    @State private var isImporting = false
    @State private var page = 0
    @State private var input = ""
    @FocusState private var chatInputFocused: Bool
    @State private var imageItem: PhotosPickerItem?
    @State private var imageURL: URL?
    @StateObject private var speaker = SpeechPlayer()
    @State private var settingsOpen = false
    @State private var pendingDeletion: URL?
    @State private var showDeleteDialog = false
    @State private var imageNotice = ""
    @State private var clearChatPrompt = false
    @AppStorage("LL.v4.accent") private var accentChoice = "mint"
    @AppStorage("LL.v4.compact") private var compactBubbles = false

    @AppStorage("LL.v3.context") private var contextLength = 4096
    @AppStorage("LL.v3.gpuLayers") private var gpuLayers = 999
    @AppStorage("LL.v3.maxTokens") private var maxTokens = 768
    @AppStorage("LL.v3.temperature") private var temperature = 0.7
    @AppStorage("LL.v3.topP") private var topP = 0.95
    @AppStorage("LL.v3.topK") private var topK = 40
    @AppStorage("LL.v3.reasoningBudget") private var reasoningBudget = 0
    @AppStorage("LL.v3.minImageFreeMB") private var minImageFreeMB = 1400
    @AppStorage("LL.v3.imageSize") private var imageSize = 512
    @AppStorage("LL.v3.systemPrompt") private var systemPrompt = ""
    @AppStorage("LL.v3.stopWords") private var stopWords = ""
    @AppStorage("LL.v3.tts") private var readAloud = false


    private let background = Color(red: 0.035, green: 0.055, blue: 0.09)
    private let panel = Color(red: 0.075, green: 0.105, blue: 0.16)
    private let panelRaised = Color(red: 0.105, green: 0.145, blue: 0.21)
    private var mint: Color {
        accentChoice == "violet" ? Color(red: 0.79, green: 0.67, blue: 1.0) :
        accentChoice == "blue" ? Color(red: 0.49, green: 0.74, blue: 1.0) :
        Color(red: 0.42, green: 0.94, blue: 0.78)
    }
    private let azure = Color(red: 0.48, green: 0.68, blue: 1.0)

    private var ggufType: UTType { UTType(filenameExtension: "gguf") ?? .data }
    private var busy: Bool { runtime.loading || runtime.generating }
    private var canLoadLanguage: Bool { !selectedLanguage.isEmpty && !busy }
    private var canLoadVision: Bool { !selectedLanguage.isEmpty && !selectedProjector.isEmpty && !busy }

    var body: some View {
        VStack(spacing: 0) {
            header
            if page == 0 {
                chatPanel
            } else if page == 1 {
                modelPanel
            } else {
                ChatsLibraryView(runtime: runtime, accent: mint) {
                    withAnimation(.easeInOut(duration: 0.16)) { page = 0 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [ggufType, .data]) { result in
            switch result {
            case .failure(let error):
                files.notice = error.localizedDescription
            case .success(let url):
                let previous = Set((importRole == .vision ? files.projectors : files.weights).map(\.path))
                files.importFile(url, asProjector: importRole == .vision)
                let changed = importRole == .vision ? files.projectors : files.weights
                if let added = changed.first(where: { !previous.contains($0.path) }) {
                    if importRole == .vision { selectedProjector = added.path }
                    else { selectedLanguage = added.path }
                }
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.lastPathComponent ?? "model")?",
            isPresented: $showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("Delete file permanently", role: .destructive) {
                if let url = pendingDeletion {
                    if url.path == runtime.loadedModelPath || url.path == runtime.loadedProjectorPath {
                        files.notice = "Offload the active model before deleting this file."
                    } else {
                        files.deleteFile(url)
                        if !files.weights.contains(where: { $0.path == selectedLanguage }) {
                            selectedLanguage = files.weights.first?.path ?? ""
                        }
                        if !files.projectors.contains(where: { $0.path == selectedProjector }) {
                            selectedProjector = files.projectors.first?.path ?? ""
                        }
                    }
                }
                pendingDeletion = nil
            }
        } message: {
            Text("This will remove the GGUF from LocalLens storage.")
        }
        .sheet(isPresented: $settingsOpen) { settingsSheet }
        .confirmationDialog("Clear this conversation?", isPresented: $clearChatPrompt,
                            titleVisibility: .visible) {
            Button("Clear messages", role: .destructive) { runtime.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The messages in this chat will be deleted. Other chats are safe.")
        }
        .onChange(of: page) { _, _ in
            chatInputFocused = false
        }
        .task {
            while !Task.isCancelled {
                runtime.refreshMemoryStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onChange(of: runtime.generating) { wasGenerating, generating in
            if wasGenerating && !generating && readAloud,
               let answer = runtime.messages.last,
               answer.role == "assistant" {
                speaker.speak(answer.text)
            }
        }
        .onAppear {
            if selectedLanguage.isEmpty { selectedLanguage = files.weights.first?.path ?? "" }
            if selectedProjector.isEmpty { selectedProjector = files.projectors.first?.path ?? "" }
        }
        .onChange(of: imageItem) { _, selected in
            guard let selected else { return }
            imageNotice = "Preparing image…"
            let target = max(256, min(1024, imageSize))
            Task {
                guard let data = try? await selected.loadTransferable(type: Data.self) else {
                    imageNotice = "Cannot read that image. Choose another."
                    return
                }
                // Downsampling through ImageIO avoids fully decoding large photos.
                // UIImage(data:) at original resolution can add hundreds of MB.
                if data.count > 35_000_000 {
                    imageNotice = "Image is too large (35 MB limit)."
                    return
                }
                let prepared = await Task.detached(priority: .userInitiated) {
                    () -> URL? in
                    autoreleasepool {
                        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: target,
                                kCGImageSourceShouldCacheImmediately: false
                              ] as CFDictionary)
                        else { return nil }
                        let reduced = UIImage(cgImage: image)
                        guard let jpeg = reduced.jpegData(compressionQuality: 0.72) else { return nil }
                        let path = FileManager.default.temporaryDirectory
                            .appendingPathComponent("locallens-\(UUID().uuidString).jpg")
                        do {
                            try jpeg.write(to: path, options: .atomic)
                            return path
                        } catch { return nil }
                    }
                }.value
                if let prepared {
                    imageURL = prepared
                    imageNotice = ""
                } else {
                    imageNotice = "Image preparation failed; no image sent."
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [mint.opacity(0.23), azure.opacity(0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(mint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("LocalLens")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("PRIVATE • ON DEVICE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.gray)
                }
                Spacer()
                Button {
                    runtime.newConversation()
                    withAnimation { page = 0 }
                    chatInputFocused = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(busy)
                .accessibilityLabel("New chat")
                Button { settingsOpen = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17))
                        .foregroundStyle(mint)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Settings")
                HStack(spacing: 6) {
                    Circle()
                        .fill(runtime.ready ? mint : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(runtime.ready ? "LOADED" : "OFFLINE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(runtime.ready ? mint : .gray)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(panelRaised, in: Capsule())
            }
            HStack(spacing: 6) {
                pageButton("Chats", icon: "clock.arrow.circlepath", index: 2)
                pageButton("Chat", icon: "bubble.left.and.bubble.right", index: 0)
                pageButton("Models", icon: "cpu", index: 1)
            }
            .padding(5)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 19)
        .padding(.top, 9)
        .padding(.bottom, 15)
    }

    private func pageButton(_ name: String, icon: String, index: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { page = index } } label: {
            Label(name, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(page == index ? .white : .gray)
                .background(page == index ? panelRaised : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var modelPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Model library")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Two components. One local intelligence.")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                HStack(spacing: 11) {
                    numberTile("\(files.weights.count)", "GGUF MODELS", icon: "cpu", color: mint)
                    numberTile("\(files.projectors.count)", "PROJECTORS", icon: "eye", color: azure)
                }

                // A language model and its vision projector are separate file types.
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("01", "Language model", "text.bubble.fill", tint: mint)
                    Text("Choose the GGUF weights to run on your device.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    if files.weights.isEmpty {
                        emptyFile("No language models imported")
                    }
                    ForEach(files.weights, id: \.path) { file in
                        selectableFile(file, selected: selectedLanguage == file.path, tint: mint) {
                            selectedLanguage = file.path
                        }
                    }
                    actionButton("Import language model", "plus.circle.fill", color: panelRaised, textColor: mint) {
                        importRole = .language
                        isImporting = true
                    }
                    actionButton(runtime.loading ? "Loading…" : "Load text model",
                                 "play.fill", color: mint, textColor: background) {
                        runtime.load(modelPath: selectedLanguage, projectorPath: nil, context: contextLength, gpuLayers: gpuLayers, systemPrompt: systemPrompt)
                    }
                    .disabled(!canLoadLanguage)
                    .opacity(canLoadLanguage ? 1 : 0.45)
                }
                .cardSurface()

                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("02", "Vision projector", "eye.fill", tint: azure)
                    Text("Import the matching mmproj GGUF. Select it below, then load it together with the language model.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    if files.projectors.isEmpty {
                        emptyFile("No vision projectors imported")
                    }
                    ForEach(files.projectors, id: \.path) { file in
                        selectableFile(file, selected: selectedProjector == file.path, tint: azure) {
                            selectedProjector = file.path
                        }
                    }
                    actionButton("Import vision projector", "plus.circle.fill", color: panelRaised, textColor: azure) {
                        importRole = .vision
                        isImporting = true
                    }
                    actionButton(runtime.loading ? "Loading…" : "Load vision with model",
                                 "eye.fill", color: azure, textColor: background) {
                        runtime.load(modelPath: selectedLanguage, projectorPath: selectedProjector, context: contextLength, gpuLayers: gpuLayers, systemPrompt: systemPrompt)
                    }
                    .disabled(!canLoadVision)
                    .opacity(canLoadVision ? 1 : 0.45)
                    Label("The projector cannot run by itself. It is loaded with the selected language model.",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .cardSurface()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("ENGINE STATUS", systemImage: "waveform.path.ecg")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.7)
                            .foregroundStyle(.gray)
                        Spacer()
                        if runtime.loading { ProgressView().tint(mint) }
                    }
                    if runtime.ready {
                        Button("Offload current model", systemImage: "eject") { runtime.unload() }
                            .font(.system(size: 13, weight: .semibold))
                            .disabled(busy)
                    }
                    Text(runtime.memoryStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.gray)
                    if !runtime.lastStats.isEmpty {
                        Text(runtime.lastStats)
                            .font(.caption.monospaced())
                            .foregroundStyle(.gray)
                    }
                    Text(runtime.status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(runtime.ready ? mint : .white)
                        .textSelection(.enabled)
                    if !files.notice.isEmpty {
                        Text(files.notice)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    if runtime.ready {
                        Button { page = 0 } label: {
                            HStack {
                                Text("Open chat")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 14, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .cardSurface()
                Text("FILES APP  ·  On My iPhone → LocalLens → Models")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray)
                    .padding(.bottom, 15)
            }
            .padding(.horizontal, 19)
            .padding(.bottom, 25)
        }
    }

    private func numberTile(_ value: String, _ caption: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 21))
                .foregroundStyle(color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(caption)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 17))
    }

    private func sectionHeading(_ count: String, _ name: String, _ icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(count)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(name)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private func emptyFile(_ message: String) -> some View {
        Label(message, systemImage: "tray")
            .font(.system(size: 13))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 15)
    }

    private func selectableFile(_ url: URL, selected: Bool, tint: Color,
                                action: @escaping () -> Void) -> some View {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 11) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? tint : .gray)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.white)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                pendingDeletion = url
                showDeleteDialog = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 37, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(busy || url.path == runtime.loadedModelPath || url.path == runtime.loadedProjectorPath)
            .accessibilityLabel("Delete \(url.lastPathComponent)")
        }
        .background(selected ? tint.opacity(0.12) : panelRaised,
                    in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(selected ? tint.opacity(0.5) : Color.white.opacity(0.055), lineWidth: 1))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                pendingDeletion = url
                showDeleteDialog = true
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, color: Color,
                              textColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 13, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(textColor)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Runtime & Memory") {
                    Picker("Context window", selection: $contextLength) {
                        Text("2,048").tag(2048)
                        Text("4,096").tag(4096)
                        Text("8,192").tag(8192)
                        Text("16,384").tag(16384)
                    }
                    Picker("Metal GPU layers", selection: $gpuLayers) {
                        Text("CPU only").tag(0)
                        Text("20 layers").tag(20)
                        Text("40 layers").tag(40)
                        Text("All available").tag(999)
                    }
                    Picker("Image resolution", selection: $imageSize) {
                        Text("256px · safest").tag(256)
                        Text("512px · recommended").tag(512)
                        Text("768px").tag(768)
                        Text("1024px · higher memory").tag(1024)
                    }
                    Picker("Minimum free RAM for image processing", selection: $minImageFreeMB) {
                        Text("1,000 MB").tag(1000)
                        Text("1,400 MB · recommended").tag(1400)
                        Text("1,800 MB · safer").tag(1800)
                        Text("2,400 MB · most conservative").tag(2400)
                    }
                    Text("Changes to GPU and context take effect when you next load a model.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    Picker("Accent color", selection: $accentChoice) {
                        Text("Mint").tag("mint")
                        Text("Ocean blue").tag("blue")
                        Text("Violet").tag("violet")
                    }
                    Toggle("Compact message bubbles", isOn: $compactBubbles)
                }
                Section("Generation") {
                    Stepper("Maximum tokens: \(maxTokens)", value: $maxTokens, in: 64...4096, step: 64)
                    VStack(alignment: .leading) {
                        Text(String(format: "Temperature: %.2f", temperature))
                        Slider(value: $temperature, in: 0...1.5, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Top P: %.2f", topP))
                        Slider(value: $topP, in: 0.1...1, step: 0.05)
                    }
                    Stepper("Top K: \(topK)", value: $topK, in: 0...200, step: 5)
                    Picker("Reasoning budget", selection: $reasoningBudget) {
                        Text("Unrestricted").tag(0)
                        Text("256 tokens").tag(256)
                        Text("768 tokens").tag(768)
                    }
                }
                Section("Prompt & Conversation") {
                    TextField("System prompt", text: $systemPrompt, axis: .vertical)
                        .lineLimit(3...7)
                    TextField("Stop sequences (one per line)", text: $stopWords, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Read finished answers aloud", isOn: $readAloud)
                    Button("Clear current chat", role: .destructive) { clearChatPrompt = true }
                        .disabled(busy)
                    Text("Chats are stored locally and restored after reopening.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Connectivity") {
                    HStack {
                        Label("MCP tools", systemImage: "network")
                        Spacer()
                        Text("Coming Soon").foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://huggingface.co/models?library=gguf")!) {
                        Label("Browse GGUF models on Hugging Face", systemImage: "arrow.up.right.square")
                    }
                    Text("Web search and remote tool execution are not enabled in this build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Memory — live measurements") {
                    LabeledContent("Device physical RAM", value: runtime.installedRAM)
                    LabeledContent("LocalLens / container RAM in use", value: runtime.currentAppRAM)
                    LabeledContent("More memory iOS permits this app", value: runtime.remainingAppBudget)
                    Text("These are different numbers. The last one is not free iPhone RAM; it is an iOS process-allocation estimate. Metal and LiveContainer may affect the app footprint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Updated \(runtime.memoryLastChecked)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { runtime.refreshMemoryStatus() }
                    }
                    .font(.footnote)
                }
                Section("Generation diagnostics") {
                    Text(runtime.lastStats.isEmpty ? "No generation statistics yet." : runtime.lastStats)
                        .textSelection(.enabled)
                    Text("The RAM limit cannot be increased by changing this display. Photo safety checks still use remaining process headroom.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { settingsOpen = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.activeConversation?.title ?? "New conversation")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(runtime.ready ? mint : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(runtime.ready ?
                             (runtime.vision ? "Vision model ready" : "Local text model ready") :
                             "Select a model to begin")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if runtime.generating {
                    ProgressView().tint(mint)
                }
                Button {
                    withAnimation { page = 2 }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 17))
                        .frame(width: 37, height: 39)
                        .foregroundStyle(.white)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("All chats")
                Menu {
                    Button {
                        runtime.newConversation()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    Button {
                        clearChatPrompt = true
                    } label: {
                        Label("Clear this chat", systemImage: "trash")
                    }
                    .disabled(busy || runtime.messages.isEmpty)
                    if let chat = runtime.activeConversation {
                        Button {
                            runtime.togglePin(chat.id)
                        } label: {
                            Label(chat.pinned ? "Unpin chat" : "Pin chat",
                                  systemImage: chat.pinned ? "pin.slash" : "pin")
                        }
                        ShareLink(item: chat.exportedText) {
                            Label("Share transcript", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 39)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Chat options")
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 13)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compactBubbles ? 9 : 16) {
                        if runtime.messages.isEmpty {
                            emptyChat
                        }
                        ForEach(runtime.messages) { message in
                            messageCard(message)
                                .id(message.id)
                        }
                        if runtime.generating {
                            HStack(spacing: 7) {
                                ProgressView().tint(mint)
                                Text(runtime.vision ? "Analyzing…" : "Generating…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 42)
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture { chatInputFocused = false }
                .onChange(of: runtime.messages.count) { _, _ in
                    if let id = runtime.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scroll.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            if !imageNotice.isEmpty {
                Text(imageNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 18)
            }
            if let url = imageURL {
                HStack(spacing: 10) {
                    if let preview = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: preview)
                            .resizable().scaledToFill()
                            .frame(width: 41, height: 41)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image attached").font(.system(size: 12, weight: .semibold))
                        Text("Will be processed locally").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        imageURL = nil
                        imageItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            HStack(alignment: .bottom, spacing: 9) {
                if chatInputFocused {
                    Button { chatInputFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 17))
                            .foregroundStyle(mint)
                            .frame(width: 29, height: 44)
                    }
                    .accessibilityLabel("Hide keyboard")
                }
                PhotosPicker(selection: $imageItem, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(runtime.vision ? mint : .gray)
                        .frame(width: 35, height: 44)
                }
                .disabled(!runtime.vision || busy)
                .accessibilityLabel("Attach image")

                TextField("Message LocalLens", text: $input, axis: .vertical)
                    .focused($chatInputFocused)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 19))
                    .submitLabel(.send)
                if runtime.generating {
                    Button { runtime.stop() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                            .frame(width: 37, height: 45)
                    }
                } else {
                    Button { sendMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(mint)
                            .frame(width: 37, height: 45)
                    }
                    .disabled(!runtime.ready || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageURL == nil))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    private var emptyChat: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle().fill(mint.opacity(0.10)).frame(width: 102, height: 102)
                Circle().strokeBorder(mint.opacity(0.28), lineWidth: 1)
                    .frame(width: 86, height: 86)
                Image(systemName: "sparkles")
                    .font(.system(size: 35, weight: .light))
                    .foregroundStyle(mint)
            }
            Text("Your space to think.")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(runtime.ready ?
                 "Ask a question, build an idea, or attach a photo." :
                 "Everything stays on your iPhone.\nChoose a model before your first message.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if !runtime.ready {
                Button {
                    withAnimation { page = 1 }
                } label: {
                    Label("Choose a model", systemImage: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(mint, in: Capsule())
                }
            } else {
                VStack(spacing: 9) {
                    suggestion("Explain something simply", icon: "lightbulb")
                    suggestion("Help me write some code", icon: "chevron.left.forwardslash.chevron.right")
                    suggestion("Brainstorm a creative idea", icon: "wand.and.stars")
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.bottom, 40)
    }

    private func suggestion(_ title: String, icon: String) -> some View {
        Button {
            input = title
            chatInputFocused = true
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(mint)
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func messageCard(_ message: LocalChat) -> some View {
        let fromUser = message.role == "user"
        return HStack(alignment: .top, spacing: 9) {
            if fromUser { Spacer(minLength: 40) }
            if !fromUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(mint)
                    .frame(width: 28, height: 28)
                    .background(mint.opacity(0.12), in: Circle())
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(fromUser ? "YOU" : "LOCALLENS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(fromUser ? azure : mint)
                Text(.init(message.text.isEmpty ? "…" : message.text))
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
            .padding(compactBubbles ? 11 : 14)
            .background(fromUser ? azure.opacity(0.12) : Color.white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy message", systemImage: "doc.on.doc")
                }
                if !fromUser {
                    Button {
                        speaker.speak(message.text)
                    } label: {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                    }
                }
                ShareLink(item: message.text) {
                    Label("Share message", systemImage: "square.and.arrow.up")
                }
            }
            if !fromUser { Spacer(minLength: 12) }
        }
    }

    private func sendMessage() {
        let applied = runtime.send(
            text: input,
            imagePath: imageURL?.path,
            options: RunSettings(
                maxTokens: maxTokens,
                temperature: Float(temperature),
                topP: Float(topP),
                topK: topK,
                reasoningBudget: reasoningBudget,
                stopWords: stopWords.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
            ),
            systemPrompt: systemPrompt,
            minimumImageMemoryMB: minImageFreeMB
        )
        if applied {
            chatInputFocused = false
            input = ""
            imageURL = nil
            imageItem = nil
            imageNotice = ""
        }
    }

}

private extension View {
    func cardSurface() -> some View {
        self.padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}
