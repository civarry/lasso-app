import Foundation
import Network
@testable import Lasso

/// A loopback HTTP server for package tests: records every request it gets and answers with what the
/// test set (a status, a body, a redirect).
final class RecordingServer: @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = Data("{}".utf8)
        var location: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "lasso.tests.recording-server")
    private let lock = NSLock()
    private var received: [HTTPRequest] = []
    private var answer = Answer()
    private(set) var port: Int = 0

    var requests: [HTTPRequest] { lock.withLock { received } }
    var base: String { "http://127.0.0.1:\(port)" }

    func answer(_ a: Answer) { lock.withLock { answer = a } }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let e): if once.claim() { continuation.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                let a = self.lock.withLock { () -> Answer in self.received.append(request); return self.answer }
                var head = "HTTP/1.1 \(a.status) X\r\nContent-Type: application/json\r\nContent-Length: \(a.body.count)\r\nConnection: close\r\n"
                if let location = a.location { head += "Location: \(location)\r\n" }
                c.send(content: Data((head + "\r\n").utf8) + a.body, isComplete: true,
                       completion: .contentProcessed { _ in c.cancel() })
            } else if error != nil || done {
                c.cancel()
            } else {
                self.receive(c, buffer)
            }
        }
    }
}
