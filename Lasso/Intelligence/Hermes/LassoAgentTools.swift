import AppKit
import CoreGraphics
import ImageIO

/// What Lasso adds to its Agent's tools: its eyes. Hermes can run commands and read files, but it can't
/// see, and the model it thinks with often can't either (Lasso serves MLX models to it text-only). These
/// use what Lasso already has: screen capture with Lasso's permission, the user's own drag-to-select,
/// Apple's on-device text recognition, and the image model chosen in Settings.
///
/// Kept to two tools on purpose. Every tool's description is read with every request, and on a local
/// model that's both context and seconds; anything a command already does well (the clipboard with
/// pbcopy/pbpaste, opening apps with `open`) is left to the terminal.
@MainActor
enum LassoAgentTools {
    nonisolated static let lookAtScreen = "look_at_screen"
    nonisolated static let lookAtImage = "look_at_image"

    /// MCP `tools/list` entries.
    nonisolated(unsafe) static let definitions: [[String: Any]] = [
        [
            "name": lookAtScreen,
            "description": "See the user's screen. Returns the text on it, a description, and the saved image's path. "
                + "area \"select\" lets the user drag around the part they mean (use it when they say \"this\" or \"here\"); "
                + "\"screen\" captures the whole main display.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "area": ["type": "string", "enum": ["select", "screen"]],
                    "question": ["type": "string", "description": "What to look for (guides the description)."],
                ],
                "required": ["area"],
            ] as [String: Any],
        ],
        [
            "name": lookAtImage,
            "description": "Read an image file on this Mac (png, jpg, heic, pdf page, screenshot): returns the text in it "
                + "and a description. Use it for any image you can't see yourself.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path, or relative to the working folder."],
                    "question": ["type": "string", "description": "What to look for (guides the description)."],
                ],
                "required": ["path"],
            ] as [String: Any],
        ],
    ]

    struct Result: Equatable {
        var text: String
        var isError = false
    }

    static func call(_ name: String, arguments: [String: Any]) async -> Result {
        let question = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch name {
        case lookAtScreen:
            let select = (arguments["area"] as? String) != "screen"
            guard CGPreflightScreenCaptureAccess() else {
                return Result(text: "Lasso doesn't have Screen Recording permission. Ask the user to turn it on in "
                    + "System Settings > Privacy & Security > Screen Recording.", isError: true)
            }
            let image: CGImage?
            if select {
                image = await CaptureCoordinator.shared.selectForAgent()
                guard image != nil else { return Result(text: "The user cancelled the selection (or a capture was already open).") }
            } else {
                image = try? await mainDisplay()
            }
            guard let image else { return Result(text: "Couldn't capture the screen.", isError: true) }
            let saved = save(image, folder: "Screenshots")
            return Result(text: await report(image, question: question, saved: saved))
        case lookAtImage:
            guard let raw = arguments["path"] as? String, !raw.isEmpty else {
                return Result(text: "Give the image's path.", isError: true)
            }
            let url = resolve(raw)
            guard let image = load(url) else {
                return Result(text: "Couldn't open \(url.path) as an image.", isError: true)
            }
            return Result(text: await report(image, question: question, saved: nil))
        default:
            return Result(text: "Lasso has no tool named \(name).", isError: true)
        }
    }

    // MARK: Seeing

    /// Text first (exact, and all a text-only model can use), then what the image model sees.
    static func report(_ image: CGImage, question: String, saved: URL?) async -> String {
        var parts: [String] = []
        if let saved { parts.append("Saved to \(saved.path) (show it with MEDIA:\(saved.path)).") }
        let text = (try? await OCREngine().recognize(image).text) ?? ""
        parts.append(text.isEmpty ? "No text found in it." : "Text in it:\n" + clipped(text, to: 6000))
        let intelligence = IntelligenceCoordinator.shared
        if let vision = await intelligence.activeVisionProvider() {
            let prompt = question.isEmpty ? "Describe this image in detail." : "Describe this image in detail to help answer: \(question)"
            do {
                let description = try await vision.describe(image, prompt: prompt)
                parts.append("What it shows (\(intelligence.imageEngineLabel)):\n" + clipped(description, to: 3000))
            } catch {
                parts.append("The image model couldn't describe it: \(error.localizedDescription)")
            }
        } else {
            parts.append("No image model is set up in Lasso, so only the text above is available.")
        }
        return parts.joined(separator: "\n\n")
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n[… cut, \(text.count - limit) more characters]"
    }

    /// The display the user is working on (the one with the key window), else the first.
    private static func mainDisplay() async throws -> CGImage? {
        let shots = try await ScreenCaptureService.captureAllDisplays()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let mainID = (NSScreen.main?.deviceDescription[key] as? NSNumber)?.uint32Value
        return (shots.first { $0.id == mainID } ?? shots.first)?.image
    }

    // MARK: Files

    static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : HermesRuntime.workspaceDirectory.appending(path: expanded)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Into the Agent's workspace, so the screenshots it took are where its other files are.
    private static func save(_ image: CGImage, folder: String) -> URL? {
        let dir = HermesRuntime.workspaceDirectory.appending(path: folder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"   // no spaces: the path goes into commands and MEDIA lines
        let url = dir.appending(path: "screen-\(formatter.string(from: Date())).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
