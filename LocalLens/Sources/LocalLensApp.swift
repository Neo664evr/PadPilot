import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import Darwin

// LocalLens: a standalone on-device GGUF chat and vision client.
struct LocalChat: Identifiable, Codable {
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
    @Published var status = "Select a language model to begin."
    @Published var loading = false
    @Published var generating = false
    @Published var ready = false
    @Published var vision = false
    @Published var lastStats = ""
    @Published var memoryStatus = ""

    private let bridge = LlamaBridge()
    private let queue = DispatchQueue(label: "locallens.inference", qos: .userInitiated)
    private var firstTurn = true
    private var gemmaDialect = false
    private var loadedSystemPrompt = ""
    private(set) var loadedModelPath: String?
    private(set) var loadedProjectorPath: String?
    private static let conversationKey = "locallens.v3.messages"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.conversationKey),
           let previous = try? JSONDecoder().decode([LocalChat].self, from: data) {
            messages = Array(previous.suffix(150))
            if !messages.isEmpty {
                status = "Chat restored. Load a model to resume."
            }
        }
        refreshMemoryStatus()
    }

    func refreshMemoryStatus() {
        #if targetEnvironment(simulator)
        memoryStatus = "Simulator memory"
        #else
        let available = Int64(os_proc_available_memory())
        memoryStatus = available > 0
            ? "Available memory: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .memory))"
            : "Available memory: unknown"
        #endif
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(messages.suffix(150))) {
            UserDefaults.standard.set(data, forKey: Self.conversationKey)
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
        guard ready else { return }
        let sys = gemmaDialect || loadedSystemPrompt.isEmpty
            ? "" : "<|im_start|>system\n\(loadedSystemPrompt)<|im_end|>\n"
        queue.async {
            do {
                try self.bridge.reset(withSystemPrompt: sys)
            } catch {
                DispatchQueue.main.async { self.status = error.localizedDescription }
            }
        }
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
        let prompt: String
        if gemma {
            let prefix = isFirst ? "" : "<end_of_turn>\n"
            let sys = isFirst && !systemPrompt.isEmpty ? systemPrompt + "\n\n" : ""
            prompt = prefix + "<start_of_turn>user\n" + sys + mediaMarker + question +
                     "<end_of_turn>\n<start_of_turn>model\n"
        } else {
            let prefix = isFirst ? "" : "<|im_end|>\n"
            prompt = prefix + "<|im_start|>user\n" + mediaMarker + question +
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
                DispatchQueue.main.async {
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
    @State private var imageItem: PhotosPickerItem?
    @State private var imageURL: URL?
    @StateObject private var speaker = SpeechPlayer()
    @State private var settingsOpen = false
    @State private var pendingDeletion: URL?
    @State private var showDeleteDialog = false
    @State private var imageNotice = ""

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
    private let mint = Color(red: 0.42, green: 0.94, blue: 0.78)
    private let azure = Color(red: 0.48, green: 0.68, blue: 1.0)

    private var ggufType: UTType { UTType(filenameExtension: "gguf") ?? .data }
    private var busy: Bool { runtime.loading || runtime.generating }
    private var canLoadLanguage: Bool { !selectedLanguage.isEmpty && !busy }
    private var canLoadVision: Bool { !selectedLanguage.isEmpty && !selectedProjector.isEmpty && !busy }

    var body: some View {
        VStack(spacing: 0) {
            header
            if page == 0 { chatPanel } else { modelPanel }
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
                    Text(runtime.ready ? "ONLINE" : "IDLE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(runtime.ready ? mint : .gray)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(panelRaised, in: Capsule())
            }
            HStack(spacing: 6) {
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
                    Button("Clear current chat", role: .destructive) { runtime.reset() }
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
                Section("Diagnostics") {
                    Text(runtime.memoryStatus)
                    Text(runtime.lastStats.isEmpty ? "No generation statistics yet." : runtime.lastStats)
                        .textSelection(.enabled)
                    Button("Refresh memory reading") { runtime.refreshMemoryStatus() }
                    Text("If iOS memory is too low, sending a photo is blocked instead of invoking the image encoder.")
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
            HStack(spacing: 8) {
                Circle().fill(runtime.ready ? mint : Color.gray).frame(width: 7, height: 7)
                Text(runtime.status)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.gray)
                Spacer()
                if runtime.ready {
                    Button {
                        runtime.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(mint)
                    }
                    .disabled(busy)
                }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 10)
            Divider().overlay(Color.white.opacity(0.04))
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        if runtime.messages.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 57, weight: .ultraLight))
                                    .foregroundStyle(mint)
                                Text("Think locally.")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(runtime.ready ? "Your private model is ready.\nStart a conversation." :
                                     "Load a model from your library\nto begin a private conversation.")
                                    .font(.system(size: 14))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.gray)
                                    .lineSpacing(4)
                                if !runtime.ready {
                                    Button("Go to model library") { page = 1 }
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.top, 6)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 90)
                        }
                        ForEach(runtime.messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 45) }
                                Text(message.text.isEmpty ? "…" : message.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 12)
                                    .background(message.role == "user" ? azure.opacity(0.18) : panel,
                                                in: RoundedRectangle(cornerRadius: 17))
                                if message.role != "user" { Spacer(minLength: 45) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(19)
                }
                .onChange(of: runtime.messages.count) { _, _ in
                    if let id = runtime.messages.last?.id {
                        withAnimation { scroll.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            if !imageNotice.isEmpty {
                Text(imageNotice).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 19)
                    .padding(.vertical, 5)
            }
            if imageURL != nil {
                HStack {
                    Image(systemName: "photo.fill").foregroundStyle(mint)
                    Text("Image attached").font(.caption).foregroundStyle(.white)
                    Spacer()
                    Button {
                        imageURL = nil
                        imageItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
            }
            HStack(alignment: .bottom, spacing: 12) {
                PhotosPicker(selection: $imageItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(runtime.vision ? mint : .gray)
                        .frame(width: 30, height: 43)
                }
                .disabled(!runtime.vision || busy)
                TextField("Ask your model…", text: $input, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .padding(12)
                    .background(panelRaised, in: RoundedRectangle(cornerRadius: 13))
                if runtime.generating {
                    Button { runtime.stop() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        let applied = runtime.send(
                            text: input,
                            imagePath: imageURL?.path,
                            options: RunSettings(
                                maxTokens: maxTokens, temperature: Float(temperature),
                                topP: Float(topP), topK: topK,
                                reasoningBudget: reasoningBudget,
                                stopWords: stopWords.components(separatedBy: .newlines)
                                    .filter { !$0.isEmpty }),
                            systemPrompt: systemPrompt,
                            minimumImageMemoryMB: minImageFreeMB
                        )
                        if applied {
                            input = ""
                            imageURL = nil
                            imageItem = nil
                            imageNotice = ""
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(mint)
                    }
                    .disabled(!runtime.ready || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageURL == nil))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(background)
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
