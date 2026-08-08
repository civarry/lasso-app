// swift-tools-version: 6.1
import PackageDescription

/// Standalone terminal harness for exercising an MLX model exactly the way `MLXProvider` does inside
/// Lasso (same `ChatSession` API, same packages, pinned to the same revisions Lasso resolves) — but
/// without the app, so you can watch the model's raw streamed output directly in Terminal while
/// iterating on prompts (e.g. the chat summarizer prompt) without going through Xcode/the UI.
///
/// Build with `xcodebuild`, NOT `swift build`/`swift run` — mlx-swift compiles its Metal shaders into
/// a `.metallib` resource bundle, and that compile step only runs under Xcode's build system; a plain
/// SwiftPM build silently skips it and the binary fails at runtime ("Failed to load the default
/// metallib"). From this directory:
///   xcodebuild build -scheme mlx-console -destination 'platform=macOS' \
///     -derivedDataPath .xcodebuild -skipPackagePluginValidation
///   echo "your prompt" | .xcodebuild/Build/Products/Debug/mlx-console
/// (omit the pipe to get an interactive multi-turn REPL instead).
let package = Package(
    name: "mlx-console",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    ],
    targets: [
        .executableTarget(
            name: "mlx-console",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        // Automated probe that drives the real ChatContextBuilder/summarizer/parseMemory logic (synced
        // copy in Sources/memory-probe/LassoMemoryCore.swift) against a live local model — see that
        // file's header for what it's testing and why.
        .executableTarget(
            name: "memory-probe",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        )
    ]
)
