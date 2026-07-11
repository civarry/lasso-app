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
                        instructions: history.instructions,
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

    private static func history(from turns: [ChatTurn]) -> (instructions: String, prior: [Chat.Message], prompt: String, role: Chat.Message.Role) {
        let visible = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let last = visible.last ?? ChatTurn(role: .user, text: "")
        // System turns (the app's chat system prompt + the injected conversation-memory and
        // semantic-retrieval blocks) become the ChatSession instructions. Previously they were dropped
        // here, which silently discarded ALL of that background context — the model only ever saw the
        // recent verbatim turns. Fall back to the built-in prompt if there are no system turns.
        let systemText = visible.dropLast()
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")
        let instructions = systemText.isEmpty ? Self.systemPrompt : systemText
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
        return (instructions, Array(prior), last.text, mlxRole(for: last.role))
    }

    /// The images attached to the latest user turn (if any), as MLX vision inputs.
    private static func images(from turns: [ChatTurn]) -> [UserInput.Image] {
        guard let base64s = turns.last(where: { $0.role == .user })?.imageBase64s else { return [] }
        return base64s.compactMap { base64 in
            guard let data = Data(base64Encoded: base64), let ciImage = CIImage(data: data) else { return nil }
            return .ciImage(ciImage)
        }
    }

    /// Whether an MLX model is a vision-language model (serves images *and* text). For a downloaded
    /// model this reads its config.json (authoritative: a VLM has a `vision_config` / VLM
    /// `model_type`); otherwise it falls back to a name heuristic until it's downloaded.
    static func isVision(_ id: String) -> Bool {
        if let config = downloadedConfig(id) {
            if config["vision_config"] != nil { return true }
            if let type = config["model_type"] as? String,
               visionModelTypes.contains(type.lowercased()) { return true }
            if let archs = config["architectures"] as? [String],
               archs.contains(where: { let a = $0.lowercased(); return a.contains("vl") || a.contains("vision") }) {
                return true
            }
            return false   // config present, no vision signal → genuinely text-only
        }
        return nameLooksVision(id)
    }

    private static let visionModelTypes: Set<String> = [
        "qwen2_vl", "qwen2_5_vl", "llava", "llava_next", "paligemma", "pixtral", "idefics2",
        "idefics3", "mllama", "internvl_chat", "molmo", "smolvlm", "minicpm-v", "gemma3",
    ]

    private static func nameLooksVision(_ id: String) -> Bool {
        let n = id.lowercased()
        return n.contains("-vl") || n.contains("vl-") || n.contains("vlm") || n.contains("vision")
            || n.contains("llava") || n.contains("paligemma") || n.contains("pixtral")
            || n.contains("moondream") || n.contains("internvl") || n.contains("smolvlm")
            || n.contains("minicpm-v")
    }

    /// Read a downloaded model's config.json from the HF cache snapshot (nil if not downloaded).
    /// The model's max input length from its downloaded config — used to truncate embedding inputs so a
    /// long chunk can't feed out-of-range positions to a fixed-window encoder. Falls back to 512 (the
    /// common BERT default) when unknown.
    static func maxSequenceLength(_ id: String) -> Int {
        let cfg = downloadedConfig(id)
        let n = (cfg?["max_position_embeddings"] as? Int)
            ?? (cfg?["n_positions"] as? Int)
            ?? (cfg?["max_seq_length"] as? Int)
        return n.map { max(16, min($0, 8192)) } ?? 512
    }

    private static func downloadedConfig(_ id: String) -> [String: Any]? {
        let snapshots = MLXCache.directory(for: id).appendingPathComponent("snapshots", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let url = dir.appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
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
                "Download the MLX vision model first in Settings ▸ Intelligence ▸ Image model.")
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
    /// In-flight first-loads, so concurrent callers for the same model share one load instead of each
    /// loading a full copy (the chat answer + the background summary hit MLX at the same time).
    private var loading: [String: Task<ModelContainer, Error>] = [:]
    private var idleEviction: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private static let idleSeconds: UInt64 = 180   // free loaded models after 3 min of no use

    private init() {
        // Cap MLX's GPU buffer cache so freed buffers return to the OS instead of accumulating across
        // a long session (flattens the in-session memory creep). Tunable; lower = less RAM, slightly
        // slower generation. Active weights + KV cache are unaffected.
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    func container(for modelID: String,
                   progress: (@Sendable (Progress) -> Void)? = nil) async throws -> ModelContainer {
        startMemoryPressureMonitorIfNeeded()
        scheduleIdleEviction()
        if let container = containers[modelID] {
            Log.mlx.notice("reuse \(modelID, privacy: .public) (in memory) · mem=\(MemoryReport.footprintMB(), privacy: .public)MB")
            return container
        }
        // Coalesce: if this model is already loading, wait for that load instead of starting a second
        // (two concurrent loads transiently double memory — e.g. chat answer + background summary).
        if let inFlight = loading[modelID] {
            Log.mlx.notice("join in-flight load \(modelID, privacy: .public)")
            return try await inFlight.value
        }
        Log.mlx.notice("load START \(modelID, privacy: .public) · mem=\(MemoryReport.footprintMB(), privacy: .public)MB")
        let t0 = Date()
        let task = Task<ModelContainer, Error> { [progress] in
            if let progress {
                return try await #huggingFaceLoadModelContainer(
                    configuration: ModelConfiguration(id: modelID), progressHandler: progress)
            }
            return try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(id: modelID))
        }
        loading[modelID] = task
        defer { loading[modelID] = nil }
        let container = try await task.value
        containers[modelID] = container
        MLXProvider.markDownloaded(modelID)   // a successful load means it's cached on disk
        scheduleIdleEviction()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Log.mlx.notice("load DONE \(modelID, privacy: .public) in \(ms, privacy: .public)ms · loaded=\(self.containers.count, privacy: .public) · mem=\(MemoryReport.footprintMB(), privacy: .public)MB")
        return container
    }

    func evict(_ key: String) { containers[key] = nil }

    /// Drop all cached models and release MLX's GPU buffer cache to free unified memory.
    func evictAll(reason: String) {
        guard !containers.isEmpty else { return }
        let count = containers.count
        let before = MemoryReport.footprintMB()
        containers.removeAll()
        MLX.Memory.clearCache()   // release MLX's GPU buffer cache
        Log.mlx.notice("EVICT \(count, privacy: .public) model(s) [\(reason, privacy: .public)] · mem \(before, privacy: .public)→\(MemoryReport.footprintMB(), privacy: .public)MB")
    }

    private func scheduleIdleEviction() {
        idleEviction?.cancel()
        idleEviction = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.evictAll(reason: "idle 3m")
        }
    }

    private func startMemoryPressureMonitorIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { Task { await MLXModelCache.shared.evictAll(reason: "memory pressure") } }
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
        // Local-only mode promises zero incidental egress — don't probe Hugging Face for the size.
        guard !PrivacyMode.localOnly else { return nil }
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
            guard (item["type"] as? String) == "file",
                  let path = item["path"] as? String, countsTowardDownload(path) else { return sum }
            let size = (item["size"] as? NSNumber)?.int64Value ?? Int64(item["size"] as? Int ?? 0)
            return sum + size
        }
        return total > 0 ? total : nil
    }

    /// Whether a repo file is actually fetched by the MLX loader (which globs safetensors + config +
    /// tokenizer). HF repos often ship duplicate weight formats (PyTorch `.bin`, ONNX, TF `.h5`) that
    /// MLX never downloads — counting them badly over-estimated small models (e.g. e5-small: 120 MB
    /// downloaded, but the whole repo is 2.3 GB).
    private static func countsTowardDownload(_ path: String) -> Bool {
        let p = path.lowercased()
        guard p.hasSuffix(".safetensors") || p.hasSuffix(".json") || p.hasSuffix(".txt")
            || p.hasSuffix(".model") || p.hasSuffix(".tiktoken") else { return false }
        return !(p.contains("onnx/") || p.contains("openvino/") || p.contains("coreml/"))
    }
}
