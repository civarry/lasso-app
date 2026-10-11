import Testing
import Foundation
@testable import Lasso

/// MLX models downloaded outside Lasso (huggingface-cli --local-dir into ~/models, LM Studio) were
/// reported "not downloaded" because only the Hugging Face cache was checked.
struct MLXLocalModelsTests {
    /// A scratch models root: org/name folders with or without weights.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-models-\(UUID())")
        func model(_ path: String, weights: Bool) throws {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            if weights { try Data([0]).write(to: dir.appendingPathComponent("model.safetensors")) }
        }
        try model("TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4", weights: true)
        try model("mlx-community/Qwen2.5-Coder-1.5B-4bit", weights: true)
        try model("Qwen3.5-9B-MTP-4bit", weights: true)          // no org folder
        try model("HauhauCS/Only-A-Readme", weights: false)        // not a model
        return root
    }

    @Test func findsARepoIDInAModelsFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4"
        #expect(MLXLocalModels.folder(for: id, roots: [root]) == root.appendingPathComponent(id))
        #expect(MLXLocalModels.folder(for: "HauhauCS/Only-A-Readme", roots: [root]) == nil, "no weights, no model")
        #expect(MLXLocalModels.folder(for: "mlx-community/Not-Here", roots: [root]) == nil)
        #expect(MLXProvider.isDownloaded(id, localRoots: [root]))
    }

    @Test func aFolderPathIsAModelIDToo() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Qwen3.5-9B-MTP-4bit").path
        #expect(MLXLocalModels.folder(for: path, roots: []) == URL(fileURLWithPath: path))
        #expect(MLXLocalModels.folder(for: path + "-missing", roots: []) == nil)
    }

    @Test func listsWhatsOnTheMac() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MLXLocalModels.discovered(roots: [root]).map(\.id) == [
            "mlx-community/Qwen2.5-Coder-1.5B-4bit", "Qwen3.5-9B-MTP-4bit",
            "TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4",
        ])
    }
}

/// Loads real models from ~/models through the chat's own MLX provider. Opt-in (several GB of memory):
///     TEST_RUNNER_LASSO_MLX_LOCAL=1 xcodebuild test -scheme Lasso -only-testing:LassoTests/MLXLocalModelLoadTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_MLX_LOCAL"] == "1"))
struct MLXLocalModelLoadTests {
    @Test(arguments: ["mlx-community/Qwen2.5-Coder-1.5B-4bit",
                      "TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4"])
    func runsAModelFromTheModelsFolder(_ id: String) async throws {
        try #require(MLXLocalModels.folder(for: id) != nil, "\(id) isn't in ~/models on this Mac")
        #expect(MLXProvider.isDownloaded(id))
        let t0 = Date()
        var reply = ""
        for try await delta in MLXProvider(modelID: id).respond(prompt: "Reply with one word: hello", context: nil) {
            reply += delta
            if reply.count > 200 { break }
        }
        print("[mlx-local] \(id) → \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(reply.prefix(120))")
        #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
