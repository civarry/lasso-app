import Foundation

/// The Hermes plugin that hands Lasso's tools (`LassoAgentTools`) to Lasso's own Hermes.
///
/// Hermes loads extra tools from MCP servers only when its optional `mcp` package is installed, and
/// the Homebrew install doesn't have it. A plugin needs nothing installed: it's a folder of Python in
/// the profile. This one is a thin relay: at load it asks `LassoToolServer` which tools exist, and each
/// call is forwarded there, so the tools themselves live in Swift. Written into Lasso's own profile on
/// every start, with that launch's address and token in a file only the user can read.
enum HermesLassoPlugin {
    static let name = "lasso"
    static let toolset = "lasso"

    static func install(in profile: URL, access: LassoToolsAccess?) throws {
        let dir = profile.appending(path: "plugins/\(name)", directoryHint: .isDirectory)
        guard let access else {
            try? FileManager.default.removeItem(at: dir)
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try HermesRuntime.writePrivate(manifest, to: dir.appending(path: "plugin.yaml"))
        try HermesRuntime.writePrivate(source, to: dir.appending(path: "__init__.py"))
        let json = try JSONSerialization.data(withJSONObject: ["url": access.url, "token": access.token])
        try HermesRuntime.writePrivate(String(decoding: json, as: UTF8.self), to: dir.appending(path: "access.json"))
    }

    static let manifest = """
        name: \(name)
        version: 1.0.0
        description: "Lasso's tools (seeing the screen and images). Written by Lasso; replaced on every start."
        author: Lasso
        kind: standalone

        """

    static let source = #"""
        """Lasso's tools for its agent. Written by Lasso, replaced on every start: edits don't last."""
        import json
        import os
        import urllib.request

        _HERE = os.path.dirname(os.path.abspath(__file__))
        # Lasso's server is on loopback: never through a proxy.
        _OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


        def _rpc(method, params, timeout):
            with open(os.path.join(_HERE, "access.json")) as f:
                access = json.load(f)
            body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
            request = urllib.request.Request(access["url"], data=body, headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + access["token"],
            })
            with _OPENER.open(request, timeout=timeout) as response:
                return json.loads(response.read())


        def _handler(name):
            def run(args, **kwargs):
                try:
                    # Long enough for the user to drag a selection.
                    reply = _rpc("tools/call", {"name": name, "arguments": args or {}}, 320)
                except Exception as error:
                    return json.dumps({"error": "Lasso didn't answer: %s" % error})
                result = reply.get("result") or {}
                text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
                if "error" in reply or result.get("isError"):
                    return json.dumps({"error": text or str(reply.get("error"))})
                return text
            return run


        def register(ctx):
            try:
                tools = _rpc("tools/list", {}, 5)["result"]["tools"]
            except Exception:
                return  # Lasso isn't serving its tools this launch: the agent runs without them.
            for tool in tools:
                ctx.register_tool(
                    name=tool["name"],
                    toolset="lasso",
                    schema={"name": tool["name"], "description": tool["description"],
                            "parameters": tool["inputSchema"]},
                    handler=_handler(tool["name"]),
                    emoji="👁",
                )

        """#
}
