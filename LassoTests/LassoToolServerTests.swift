import AppKit
import Foundation
import Testing
@testable import Lasso

/// Lasso's tools for its Agent, as Hermes reaches them: MCP JSON-RPC, and a real image read through
/// `look_at_image` (Apple's text recognition runs for real).
@MainActor
struct LassoToolServerTests {
    @Test func answersTheHandshakeAndListsTheTools() async throws {
        let hello = try #require(await LassoToolServer.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                               "params": ["protocolVersion": "2025-03-26"]]))
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        // The client's "initialized" notification gets no answer.
        #expect(await LassoToolServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = try #require(await LassoToolServer.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["look_at_screen", "look_at_image"])
        // Every tool's description goes out with every request: keep them short.
        let size = try JSONSerialization.data(withJSONObject: tools).count
        #expect(size < 2000, "Lasso's tool definitions grew to \(size) bytes")

        let unknown = try #require(await LassoToolServer.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func looksAtAnImageFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lasso-tool-\(UUID().uuidString.prefix(6)).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 600, height: 160), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Invoice 4471 due Friday" as NSString).draw(at: NSPoint(x: 20, y: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            return true
        }
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url)

        let reply = try #require(await LassoToolServer.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "look_at_image", "arguments": ["path": url.path]]]))
        let result = try #require(reply["result"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(result["isError"] as? Bool == false)
        #expect(text.contains("Invoice 4471"), "\(text.prefix(300))")

        let missing = try #require(await LassoToolServer.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "look_at_image", "arguments": ["path": "/nonexistent/x.png"]]]))
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func relativePathsAreInTheWorkspace() {
        #expect(LassoAgentTools.resolve("shots/a.png").path == HermesRuntime.workspaceDirectory.appending(path: "shots/a.png").path)
        #expect(LassoAgentTools.resolve("/tmp/a.png").path == "/tmp/a.png")
    }

    /// The profile trims Hermes's tools and turns on Lasso's plugin.
    @Test func profileTrimsHermesToolsAndAddsLassos() throws {
        let tools = LassoToolsAccess(url: "http://127.0.0.1:5555/mcp", token: "tok")
        let block = HermesProfileFiles.withManagedBlock("", port: 8653, route: nil, tools: tools)
        #expect(block.contains("platform_toolsets:\n  api_server: [\"terminal\", \"file\", \"web\", \"memory\", \"lasso\"]\n"))
        #expect(block.contains("plugins:\n  enabled: [\"lasso\"]\n"))
        let without = HermesProfileFiles.withManagedBlock("", port: 8653, route: nil)
        #expect(without.contains("api_server: [\"terminal\", \"file\", \"web\", \"memory\"]\n"))
        #expect(!without.contains("plugins:"))

        // The plugin's files: owner-only, the access file holding this launch's address and token.
        let profile = FileManager.default.temporaryDirectory.appending(path: "lasso-plugin-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: profile) }
        try HermesLassoPlugin.install(in: profile, access: tools)
        let dir = profile.appending(path: "plugins/lasso")
        let access = try String(contentsOf: dir.appending(path: "access.json"), encoding: .utf8)
        #expect(access.contains("\"token\":\"tok\""))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "access.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: dir.appending(path: "__init__.py"), encoding: .utf8).contains("def register(ctx):"))
        try HermesLassoPlugin.install(in: profile, access: nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path), "a launch without the tools leaves no plugin behind")
    }

    @Test func lassoToolsHaveTheirOwnSteps() {
        #expect(HermesTurn.label(for: "look_at_screen") == "Looked at your screen")
        #expect(HermesTurn.label(for: "look_at_image") == "Looked at an image")
        #expect(HermesTurn.icon(for: "look_at_image") == "eye")
        #expect(HermesTurn.label(for: "terminal") == "Ran a command")
    }
}

/// The whole-screen capture, for real: needs Screen Recording for the test host and an unlocked
/// screen. Opt-in: TEST_RUNNER_LASSO_SCREEN_TOOL=1.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_SCREEN_TOOL"] == "1"))
struct LassoScreenToolLiveTests {
    @Test func looksAtTheWholeScreen() async throws {
        let result = await LassoAgentTools.call(LassoAgentTools.lookAtScreen, arguments: ["area": "screen"])
        print("[screen-tool] \(result.text.prefix(400))")
        #expect(!result.isError)
        let saved = try #require(result.text.split(separator: "\n").first { $0.hasPrefix("Saved to ") })
        let path = String(saved.dropFirst("Saved to ".count).prefix { $0 != " " })
        #expect(path.hasPrefix(HermesRuntime.workspaceDirectory.path + "/Screenshots/screen-"))
        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }
}
