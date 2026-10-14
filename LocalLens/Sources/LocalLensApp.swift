import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// LocalLens: a standalone on-device GGUF chat and vision client.
struct LocalChat: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

final class LocalRuntime: ObservableObject {
    @Published var messages: [LocalChat] = []
    @Published var status = "Import a GGUF model to begin."
    @Published var loading = false
    @Published var generating = false
    @Published var ready = false
    @Published var vision = false

    private let bridge = LlamaBridge()
    private let queue = DispatchQueue(label: "locallens.inference", qos: .userInitiated)
    private var firstTurn = true
    private var gemmaDialect = false

    func load(modelPath: String, projectorPath: String?) {
        guard !loading && !generating else { return }
        ready = false
        loading = true
        status = "Loading model…"
        queue.async {
            self.bridge.unload()
            do {
                // The bridge ships with llama.cpp + mtmd / Metal.
                try self.bridge.loadModel(atPath: modelPath,
                                          mmprojPath: projectorPath,
                                          nCtx: 4096,
                                          nGpuLayers: 999,
                                          compressionEnabled: true)
                try self.bridge.reset(withSystemPrompt: "")
                let snapshot = self.bridge.modelInfo
                let hasVision = snapshot?.supportsVision ?? false
                let gemma = snapshot?.chatTemplate.contains("<start_of_turn>") ?? modelPath.lowercased().contains("gemma")
                DispatchQueue.main.async {
                    self.ready = true
                    self.loading = false
                    self.vision = hasVision
                    self.gemmaDialect = gemma
                    self.firstTurn = true
                    self.messages = []
                    self.status = hasVision ? "Ready · Vision enabled" : "Ready · Text chat"
                }
            } catch {
                DispatchQueue.main.async {
                    self.loading = false
                    self.status = "Load failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func reset() {
        guard ready && !loading && !generating else { return }
        queue.async {
            do {
                try self.bridge.reset(withSystemPrompt: "")
                DispatchQueue.main.async {
                    self.messages = []
                    self.firstTurn = true
                }
            } catch {
                DispatchQueue.main.async { self.status = error.localizedDescription }
            }
        }
    }

    func stop() { bridge.requestStop() }

    func send(text: String, imagePath: String?) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready && !generating && (!question.isEmpty || imagePath != nil) else { return }
        if imagePath != nil && !vision {
            status = "Load a matching mmproj projector before sending images."
            return
        }
        let answerID = UUID()
        messages.append(LocalChat(role: "user", text: (imagePath == nil ? "" : "📷 ") + question))
        messages.append(LocalChat(id: answerID, role: "assistant", text: ""))
        generating = true
        status = "Generating…"

        let isFirst = firstTurn
        firstTurn = false
        let gemma = gemmaDialect
        let mediaMarker = imagePath == nil ? "" : LlamaBridge.mediaMarker() + "\n"
        let prompt: String
        if gemma {
            let prefix = isFirst ? "" : "<end_of_turn>\n"
            prompt = prefix + "<start_of_turn>user\n" + mediaMarker + question +
                     "<end_of_turn>\n<start_of_turn>model\n"
        } else {
            let prefix = isFirst ? "" : "<|im_end|>\n"
            prompt = prefix + "<|im_start|>user\n" + mediaMarker + question +
                     "<|im_end|>\n<|im_start|>assistant\n"
        }
        let imagePaths: [String] = imagePath.map { [$0] } ?? []
        queue.async {
            let params = LMGenerationParams.defaults()
            params.maxTokens = 768
            params.temperature = 0.7
            self.bridge.generate(withPrompt: prompt,
                                 imagePaths: imagePaths,
                                 audioPaths: [],
                                 params: params,
                                 onToken: { piece in
                DispatchQueue.main.async {
                    if let index = self.messages.firstIndex(where: { $0.id == answerID }) {
                        self.messages[index].text += piece
                    }
                }
            }, onDone: { success, message, stats in
                DispatchQueue.main.async {
                    self.generating = false
                    self.status = success ? (self.vision ? "Ready · Vision enabled" : "Ready · Text chat") :
                        "Generation failed: \(message ?? "Unknown error")"
                }
            })
        }
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

    func importFile(_ picked: URL) {
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        guard picked.pathExtension.lowercased() == "gguf" else {
            notice = "Only .gguf files are supported."
            return
        }
        var dest = directory.appendingPathComponent(picked.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = picked.deletingPathExtension().lastPathComponent
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

@main
struct LocalLensApp: App {
    var body: some Scene {
        WindowGroup {
            LocalLensView()
                .preferredColorScheme(.dark)
        }
    }
}

struct LocalLensView: View {
    @StateObject private var files = ModelFiles()
    @StateObject private var runtime = LocalRuntime()
    @State private var modelPath = ""
    @State private var projPath = ""
    @State private var input = ""
    @State private var importing = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var attachedImage: URL?
    @State private var tab = 0

    private let tint = Color(red: 0.48, green: 0.72, blue: 1.0)
    private var ggufType: UTType { UTType(filenameExtension: "gguf") ?? .data }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(tint)
                Text("LocalLens")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Spacer()
                Text("OFFLINE")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(runtime.ready ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Picker("View", selection: $tab) {
                Text("Chat").tag(0)
                Text("Models").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if tab == 0 { chatPanel } else { modelPanel }
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.10))
        .tint(tint)
        .fileImporter(isPresented: $importing, allowedContentTypes: [ggufType, .data]) { result in
            switch result {
            case .success(let url):
                files.importFile(url)
                if modelPath.isEmpty, let first = files.weights.first { modelPath = first.path }
            case .failure(let error):
                files.notice = error.localizedDescription
            }
        }
        .onChange(of: pickerItem) { _, selected in
            guard let selected else { return }
            Task {
                guard let data = try? await selected.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                let maxSide: CGFloat = 1024
                let factor = min(1, maxSide / max(image.size.width, image.size.height))
                let dimension = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                let thumb = UIGraphicsImageRenderer(size: dimension).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: dimension))
                }
                if let jpeg = thumb.jpegData(compressionQuality: 0.85) {
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("lens-\(UUID().uuidString).jpg")
                    try? jpeg.write(to: path)
                    attachedImage = path
                }
            }
        }
    }

    private var modelPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("On-device models")
                    .font(.title2.bold())
                Text("Import GGUF weights and matching mmproj projectors from Files. All inference stays on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    importing = true
                } label: {
                    Label("Import GGUF / mmproj", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)

                if !files.notice.isEmpty {
                    Text(files.notice).font(.footnote).foregroundStyle(.secondary)
                }
                Text("LANGUAGE MODEL")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                if files.weights.isEmpty {
                    Text("No models imported yet.").foregroundStyle(.secondary)
                } else {
                    Picker("GGUF", selection: $modelPath) {
                        Text("Choose a model").tag("")
                        ForEach(files.weights, id: \.path) { path in
                            Text(path.lastPathComponent).tag(path.path)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("VISION PROJECTOR")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Picker("mmproj", selection: $projPath) {
                    Text("None (text only)").tag("")
                    ForEach(files.projectors, id: \.path) { path in
                        Text(path.lastPathComponent).tag(path.path)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("A projector must match its GGUF model. Incompatible files will fail to load.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    runtime.load(modelPath: modelPath, projectorPath: projPath.isEmpty ? nil : projPath)
                } label: {
                    HStack {
                        if runtime.loading { ProgressView().tint(.white) }
                        Image(systemName: "play.fill")
                        Text(runtime.loading ? "Loading…" : "Load selected model")
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(modelPath.isEmpty || runtime.loading || runtime.generating)
                Text(runtime.status)
                    .font(.footnote.monospaced())
                    .foregroundStyle(runtime.ready ? .green : .secondary)
                    .textSelection(.enabled)
                Button("Open chat") { tab = 0 }
                    .disabled(!runtime.ready)

                Divider()
                Text("Files → On My iPhone → LocalLens → Models")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Tip: Reimport files from the Files app; another app's private storage cannot be read directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: runtime.vision ? "eye.fill" : "cpu")
                Text(runtime.status)
                    .lineLimit(2)
                Spacer()
                Button {
                    runtime.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(!runtime.ready || runtime.generating)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        if runtime.messages.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 45))
                                    .foregroundStyle(tint)
                                Text("Your models. Your device.")
                                    .font(.title3.weight(.semibold))
                                Text(runtime.ready ? "Ask anything, or attach an image for a vision model." : "Import and load a model in the Models tab.")
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        }
                        ForEach(runtime.messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 45) }
                                Text(message.text.isEmpty ? "…" : message.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .padding(14)
                                    .background(message.role == "user" ? tint.opacity(0.16) : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                if message.role != "user" { Spacer(minLength: 45) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(17)
                }
                .onChange(of: runtime.messages.count) { _, _ in
                    if let last = runtime.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let attachedImage {
                HStack {
                    Image(systemName: "photo")
                    Text(attachedImage.lastPathComponent)
                        .lineLimit(1)
                        .font(.caption)
                    Spacer()
                    Button {
                        self.attachedImage = nil
                        pickerItem = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 7)
            }

            HStack(alignment: .bottom, spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .frame(width: 30, height: 42)
                }
                .disabled(!runtime.vision || runtime.generating)
                TextField("Message your local model", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                if runtime.generating {
                    Button {
                        runtime.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                            .frame(width: 38, height: 42)
                    }
                } else {
                    Button {
                        runtime.send(text: input, imagePath: attachedImage?.path)
                        input = ""
                        attachedImage = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .frame(width: 38, height: 42)
                    }
                    .disabled(!runtime.ready || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImage == nil))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 9)
        }
    }
}
