import CoreImage
import Foundation
import HuggingFace
import MLX   // GPU.clearCache to release unified memory on eviction
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLXVLM   // links the VLM model factory so the shared loader can handle vision models
import Tokenizers

/// Experimental native MLX text provider.
struct MLXProvider: IntelligenceProvider {
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    let modelID: String

    var name: String { "MLX · \(modelID)" }
    let isAppleOnDevice = false
    let isLocal = true

    init(modelID: String = Self.defaultModelID) {
        self.modelID = modelID.isEmpty ? Self.defaultModelID : modelID
    }

    func checkAvailability() async -> Bool {
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        var userContent = prompt
        if let context, !context.isEmpty {
            userContent += "\n\n--- On-screen text ---\n\(context)"
        }
        let messages = [
            ChatTurn(role: .system, text: Self.systemPrompt),
            ChatTurn(role: .user, text: userContent),
        ]
        return respond(messages: messages)
    }

    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // BYOM: never silently download on the hot path. The user downloads the model
                    // explicitly in Settings first (Hugging Face fetch leaves the Mac); here we only
                    // run it once it's local.
                    guard Self.isDownloaded(modelID) else {
                        throw IntelligenceError.unavailable(
                            PrivacyMode.localOnly
                            ? "This MLX model isn't downloaded, and Local-only mode blocks the download (it would leave your Mac). Download it once with Local-only off in Settings ▸ Intelligence."
                            : "This MLX model isn't downloaded yet. Download it in Settings ▸ Intelligence (MLX), then try again.")
                    }
                    let model = try await MLXModelCache.shared.container(for: modelID)
                    let history = Self.history(from: messages)
                    let session = ChatSession(
                        model,
                        instructions: Self.systemPrompt,
                        history: history.prior,
                        generateParameters: .init(maxTokens: 1024, temperature: 0.2))
                    // If the turn carries an image (and this is a VLM), pass it natively so one VLM
                    // can serve both text and vision — no separate vision model needed.
                    for try await chunk in session.streamResponse(
                        to: history.prompt, role: history.role,
                        images: Self.images(from: messages), videos: []) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.
    """

    private static func history(from turns: [ChatTurn]) -> (prior: [Chat.Message], prompt: String, role: Chat.Message.Role) {
        let visible = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let last = visible.last ?? ChatTurn(role: .user, text: "")
        let prior = visible.dropLast().compactMap { turn -> Chat.Message? in
            switch turn.role {
            case .system:
                return nil
            case .user:
                return .user(turn.text)
            case .assistant:
                return .assistant(turn.text)
            }
        }
        return (Array(prior), last.text, mlxRole(for: last.role))
    }

    /// The image attached to the latest user turn (if any), as an MLX vision input.
    private static func images(from turns: [ChatTurn]) -> [UserInput.Image] {
        guard let base64 = turns.last(where: { $0.role == .user })?.imageBase64,
              let data = Data(base64Encoded: base64),
              let ciImage = CIImage(data: data) else { return [] }
        return [.ciImage(ciImage)]
    }

    /// Heuristic: is this MLX model id a vision-language model (so it can serve images *and* text)?
    static func isVision(_ id: String) -> Bool {
        let n = id.lowercased()
        return n.contains("-vl") || n.contains("vl-") || n.contains("vlm") || n.contains("vision")
            || n.contains("llava") || n.contains("paligemma") || n.contains("pixtral")
            || n.contains("moondream") || n.contains("internvl") || n.contains("smolvlm")
            || n.contains("minicpm-v")
    }

    private static func mlxRole(for role: ChatTurn.Role) -> Chat.Message.Role {
        switch role {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        }
    }

    // MARK: - Download / availability (BYOM: explicit, consented, tracked)

    private static let downloadedKey = "mlx.downloadedModels"

    static func downloadedModels() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: downloadedKey) ?? [])
    }

    /// Downloaded == present in the on-disk Hugging Face cache (source of truth), so models fetched
    /// before tracking existed — or by other tools — are recognised too.
    static func isDownloaded(_ id: String) -> Bool {
        let snapshots = MLXCache.directory(for: id).appendingPathComponent("snapshots", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path),
           !entries.isEmpty {
            return true
        }
        return downloadedModels().contains(normalizedID(id))   // fallback
    }

    static func markDownloaded(_ id: String) {
        var set = downloadedModels()
        set.insert(normalizedID(id))
        UserDefaults.standard.set(Array(set), forKey: downloadedKey)
    }

    static func unmarkDownloaded(_ id: String) {
        var set = downloadedModels()
        set.remove(normalizedID(id))
        UserDefaults.standard.set(Array(set), forKey: downloadedKey)
    }

    /// Delete a downloaded model's cached files from disk and forget it (BYOM: the user manages
    /// their models). Also evicts the in-memory container so the freed model isn't reused this session.
    static func remove(_ entry: MLXCache.Entry) async throws {
        try MLXCache.remove(entry)
        unmarkDownloaded(entry.repoID)
        await MLXModelCache.shared.evict(MLXCache.directoryName(for: entry.repoID))
        await MLXModelCache.shared.evict(entry.repoID)
    }

    static func normalizedID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModelID : trimmed
    }

    /// Fetch the model into the local Hugging Face cache (explicit user action from Settings). The
    /// fetch leaves the Mac, so it's blocked in Local-only mode. Once cached, inference is fully local.
    /// `progress` reports the loader's real fraction completed (0–1).
    static func ensureDownloaded(
        _ id: String, progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let modelID = normalizedID(id)
        if PrivacyMode.localOnly, !isDownloaded(modelID) {
            throw IntelligenceError.unavailable(
                "Local-only mode is on, so the MLX model can't be downloaded (the fetch leaves your "
                + "Mac). Turn Local-only off to download it once; inference stays on-device after that.")
        }
        _ = try await MLXModelCache.shared.container(for: modelID) { p in
            progress(p.fractionCompleted)
        }
    }
}

/// Native MLX vision provider (Identify / image questions) via a local VLM, e.g. Qwen2.5-VL. Uses the
/// same downloader + cache as the text provider — the shared loader resolves the VLM factory because
/// MLXVLM is linked. BYOM: never downloads on the hot path (the user downloads it in Settings first).
struct MLXVisionProvider: VisionProvider {
    static let defaultModelID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"

    let modelID: String

    init(modelID: String = Self.defaultModelID) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = trimmed.isEmpty ? Self.defaultModelID : trimmed
    }

    func isAvailable() async -> Bool { MLXProvider.isDownloaded(modelID) }

    func describe(_ image: CGImage, prompt: String) async throws -> String {
        guard MLXProvider.isDownloaded(modelID) else {
            throw IntelligenceError.unavailable(
                "Download the MLX vision model first in Settings ▸ Intelligence ▸ Image.")
        }
        let container = try await MLXModelCache.shared.container(for: modelID)
        let session = ChatSession(
            container,
            instructions: "You are a precise vision assistant. Describe or answer about the image "
                + "accurately and concisely.",
            generateParameters: .init(maxTokens: 800, temperature: 0.2))
        return try await session.respond(to: prompt, image: .ciImage(CIImage(cgImage: image)))
    }
}

/// Caches loaded MLX model containers for the session, but frees them when idle or under memory
/// pressure — MLX weights live in unified memory, so an idle 7B/VLM would otherwise park multiple GB.
/// In-flight inference holds its own reference, so eviction never interrupts an active generation.
private actor MLXModelCache {
    static let shared = MLXModelCache()

    private var containers: [String: ModelContainer] = [:]
    private var idleEviction: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private static let idleSeconds: UInt64 = 180   // free loaded models after 3 min of no use

    private init() {}

    func container(for modelID: String,
                   progress: (@Sendable (Progress) -> Void)? = nil) async throws -> ModelContainer {
        startMemoryPressureMonitorIfNeeded()
        scheduleIdleEviction()
        if let container = containers[modelID] { return container }
        let container: ModelContainer
        if let progress {
            container = try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: modelID), progressHandler: progress)
        } else {
            container = try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: modelID))
        }
        containers[modelID] = container
        MLXProvider.markDownloaded(modelID)   // a successful load means it's cached on disk
        scheduleIdleEviction()
        return container
    }

    func evict(_ key: String) { containers[key] = nil }

    /// Drop all cached models and release MLX's GPU buffer cache to free unified memory.
    func evictAll() {
        guard !containers.isEmpty else { return }
        containers.removeAll()
        MLX.GPU.clearCache()
        Log.intelligence.notice("MLX: freed cached models to reclaim memory")
    }

    private func scheduleIdleEviction() {
        idleEviction?.cancel()
        idleEviction = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.evictAll()
        }
    }

    private func startMemoryPressureMonitorIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { Task { await MLXModelCache.shared.evictAll() } }
        source.resume()
        pressureSource = source
    }
}

/// Read-only view of the on-disk Hugging Face model cache used by MLX, for "what's downloaded" +
/// removal in Settings. Layout: <root>/models--<org>--<name>; root honours HF_HOME /
/// HUGGINGFACE_HUB_CACHE, else ~/.cache/huggingface/hub.
enum MLXCache {
    struct Entry: Identifiable {
        let repoID: String
        let url: URL
        let sizeBytes: Int64
        var id: String { url.path }
    }

    static func root() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HUGGINGFACE_HUB_CACHE"], !hub.isEmpty {
            return URL(fileURLWithPath: hub, isDirectory: true)
        }
        if let home = env["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    static func directoryName(for repoID: String) -> String {
        "models--" + MLXProvider.normalizedID(repoID).replacingOccurrences(of: "/", with: "--")
    }

    static func directory(for repoID: String) -> URL {
        root().appendingPathComponent(directoryName(for: repoID), isDirectory: true)
    }

    /// Downloaded models found on disk, with their size.
    static func installed() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root(), includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            guard name.hasPrefix("models--"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return Entry(repoID: repoID(fromDirName: name), url: url, sizeBytes: size(of: url))
        }.sorted { $0.repoID.localizedCaseInsensitiveCompare($1.repoID) == .orderedAscending }
    }

    /// "models--org--name" → "org/name" (repo ids have a single slash → first "--").
    static func repoID(fromDirName name: String) -> String {
        let stripped = String(name.dropFirst("models--".count))
        guard let range = stripped.range(of: "--") else { return stripped }
        return stripped.replacingCharacters(in: range, with: "/")
    }

    static func size(of url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    static func remove(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.url)
        // Best-effort: drop the matching lock dir too.
        let locks = root().appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent(entry.url.lastPathComponent, isDirectory: true)
        try? FileManager.default.removeItem(at: locks)
    }

    /// Total download size of a Hugging Face repo, from its file tree API (a small metadata request
    /// that leaves the Mac). nil if the repo can't be reached / doesn't exist.
    static func remoteSizeBytes(for id: String) async -> Int64? {
        let repo = MLXProvider.normalizedID(id)
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        let total = items.reduce(Int64(0)) { sum, item in
            guard (item["type"] as? String) == "file" else { return sum }
            let size = (item["size"] as? NSNumber)?.int64Value ?? Int64(item["size"] as? Int ?? 0)
            return sum + size
        }
        return total > 0 ? total : nil
    }
}
