import Foundation
import Network

/// Serves the tools in `LassoAgentTools` to Lasso's own Hermes, on loopback.
///
/// MCP-shaped JSON-RPC over HTTP POST at `/mcp` (`initialize`, `tools/list`, `tools/call`, `ping`),
/// answered with plain JSON. Hermes reaches it through Lasso's plugin (`HermesLassoPlugin`), since the
/// Homebrew Hermes can't load MCP servers; keeping the MCP shape means a real MCP client can use it too.
/// Like `LocalModelServer`: loopback only, a fresh port and a random bearer token per launch, written
/// only into Lasso's private Hermes profile.
final class LassoToolServer: @unchecked Sendable {
    static let shared = LassoToolServer()

    let token = UUID().uuidString
    private let queue = DispatchQueue(label: "lasso.tool-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: Int?

    /// `http://127.0.0.1:<port>/mcp`, starting the server if needed.
    func start() async throws -> URL {
        if let port = lock.withLock({ boundPort }) { return Self.url(port) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener; self.boundPort = port }
        Log.app.notice("tool server · Lasso's tools for Hermes on 127.0.0.1:\(port, privacy: .public)")
        return Self.url(port)
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil; self.boundPort = nil }
            return self.listener
        }
        listener?.cancel()
    }

    static func url(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 8 << 20 { connection.cancel(); return }
            if let request = HTTPRequest.parse(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let writer = ResponseWriter(connection)
        guard request.headers["authorization"] == "Bearer \(token)" else {
            await writer.json(status: 401, ["error": "Missing or wrong token."])
            return
        }
        guard request.path == "/mcp" else {
            await writer.json(status: 404, ["error": "Not found"])
            return
        }
        // GET would open a server-to-client event stream, DELETE end a session: neither is used here.
        guard request.method == "POST" else { await writer.empty(status: 405); return }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            await writer.json(status: 400, Self.failure(id: NSNull(), code: -32700, "Parse error"))
            return
        }
        if let reply = await Self.handle(message) {
            await writer.json(status: 200, reply)
        } else {
            await writer.empty(status: 202)   // a notification: nothing to answer
        }
    }

    // MARK: JSON-RPC

    /// The answer to one JSON-RPC message, or nil for a notification.
    static func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return success(id: id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "lasso", "version": Bundle.main.shortVersion],
            ])
        case "ping":
            return success(id: id, [:])
        case "tools/list":
            // Lasso's own, then the packages' tools (the Agent restarts when those change).
            let packages = PackageToolCall.agentDefinitions()
            return success(id: id, ["tools": LassoAgentTools.definitions + packages])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(id: id, code: -32602, "Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let sendable = SendableArguments(arguments)
            if HermesTurn.lassoTool(name) == nil, PackageRegistry.shared.tools().contains(where: { $0.name == name }) {
                let result = await PackageToolCall.call(name, arguments: sendable.value) { request in
                    await ChatController.shared.askForAgentTool(request)
                }
                return success(id: id, ["content": [["type": "text", "text": result.text]], "isError": result.isError])
            }
            let result = await LassoAgentTools.call(name, arguments: sendable.value)
            return success(id: id, ["content": [["type": "text", "text": result.text]], "isError": result.isError])
        default:
            return failure(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    static func success(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func failure(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

/// JSON arguments (plain strings, numbers and collections) handed to the main actor.
private struct SendableArguments: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
