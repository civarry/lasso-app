import Testing
@testable import Lasso

struct OllamaAgentModelTests {
    @Test func variantNamesAreValidOllamaNames() {
        #expect(OllamaAgentModel.name(for: "hf.co/mradermacher/Huihui-gemma-4-12B-it-abliterated-GGUF:Q4_K_M")
                == "lasso-agent/hf.co-mradermacher-huihui-gemma-4-12b-it-abliterated-gguf-q4_k_m")
        #expect(OllamaAgentModel.name(for: "qwen3:30b") == "lasso-agent/qwen3-30b")
    }

    @Test func numCtxIsReadFromShowParameters() {
        #expect(OllamaAgentModel.parseNumCtx("stop                           \"<end_of_turn>\"\nnum_ctx                        65536\ntemperature 1") == 65536)
        #expect(OllamaAgentModel.parseNumCtx("temperature 1") == nil)
    }
}
