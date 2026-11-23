import Foundation
import Testing
@testable import Lasso

/// The chat header's MLX menu offers chat models only: an embedding model (bge) can't answer.
@MainActor
struct MLXMenuTests {
    func folder(_ config: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lasso-mlx-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: url.appending(path: "config.json"))
        return url
    }

    @Test func embeddingModelsAreNotChatModels() throws {
        #expect(!MLXLocalModels.isLanguageModel(try folder(["model_type": "bert", "architectures": ["BertModel"]])))
        #expect(MLXLocalModels.isLanguageModel(try folder(["model_type": "qwen3_5", "architectures": ["Qwen3_5ForConditionalGeneration"]])))
        #expect(MLXLocalModels.isLanguageModel(try folder(["model_type": "llama", "architectures": ["LlamaForCausalLM"]])))
        #expect(MLXLocalModels.isLanguageModel(try folder(["model_type": "gpt2", "architectures": ["GPT2LMHeadModel"]])))
        #expect(MLXLocalModels.isLanguageModel(try folder(["model_type": "x"])), "no architectures: kept")
    }
}
