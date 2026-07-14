import Foundation
import Network

/// Minimal loopback HTTP server that captures a single OAuth redirect. The Codex
/// login flow redirects the browser to `http://localhost:1455/auth/callback?code=…&state=…`
/// after the user approves; this listens on that port, parses the query, serves
/// a small success page, and hands the code back to the awaiting caller.
///
/// Deliberately single-shot: `start()` binds the port (throwing if it's taken),
/// `waitForCallback()` suspends until the redirect arrives (or the deadline
/// passes), and `stop()` tears everything down. The child socket callbacks fire
/// on a background queue, so shared state is guarded by a lock.
final class OAuthLoopbackServer: @unchecked Sendable {
    struct Callback: Sendable {
        let code: String
        let state: String
    }

    enum ServerError: LocalizedError {
        case portUnavailable(UInt16)
        case timedOut
        case cancelled
        case oauthError(String)

        var errorDescription: String? {
            switch self {
            case .portUnavailable(let port):
                return "Port \(port) is already in use. Close any other sign-in in progress and try again."
            case .timedOut: return "Sign-in timed out. Please try again."
            case .cancelled: return "Sign-in was cancelled."
            case .oauthError(let message): return "Authorization failed: \(message)"
            }
        }
    }

    let port: UInt16
    private let queue = DispatchQueue(label: "com.vellum.oauth.loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private var finished = false

    init(port: UInt16) {
        self.port = port
    }

    /// Binds the loopback port. Throws `portUnavailable` if another process (or a
    /// prior sign-in) already holds it.
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: nwPort) else {
            throw ServerError.portUnavailable(port)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    /// Suspends until the browser hits `/auth/callback`, then resolves with the
    /// parsed `code`/`state`. Times out after `deadline` seconds.
    func waitForCallback(timeout deadline: TimeInterval = 300) async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(throwing: ServerError.cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
                self?.finish(.failure(ServerError.timedOut))
            }
        }
    }

    func stop() {
        finish(.failure(ServerError.cancelled))
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Accumulates bytes until the end of the HTTP request line/headers, then
    /// parses the request target. We only need the first line (`GET <target>`).
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let target = Self.requestTarget(accumulated) {
                self.respond(on: connection, target: target)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    /// Extracts the request target (`/auth/callback?...`) from the first HTTP
    /// line once the header terminator has arrived. Returns nil while more bytes
    /// are still needed.
    private static func requestTarget(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("\r\n") else { return nil }
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func respond(on connection: NWConnection, target: String) {
        let result = Self.parseCallback(target)
        let body = Self.successPage(success: {
            if case .success = result { return true }
            return false
        }())
        let response = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        finish(result)
    }

    /// Parses `?code=…&state=…` (or an `error` param) from the callback target.
    private static func parseCallback(_ target: String) -> Result<Callback, Error> {
        guard target.hasPrefix("/auth/callback"),
              let components = URLComponents(string: "http://localhost" + target) else {
            return .failure(ServerError.oauthError("unexpected callback path"))
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error") {
            let description = value("error_description") ?? error
            return .failure(ServerError.oauthError(description))
        }
        guard let code = value("code"), let state = value("state") else {
            return .failure(ServerError.oauthError("missing code or state"))
        }
        return .success(Callback(code: code, state: state))
    }

    /// Resolves the awaiting continuation exactly once and tears down sockets.
    private func finish(_ result: Result<Callback, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let openConnections = connections
        connections = []
        let listener = self.listener
        self.listener = nil
        lock.unlock()

        // Give the success page a moment to flush before closing the listener.
        queue.asyncAfter(deadline: .now() + 0.25) {
            openConnections.forEach { $0.cancel() }
            listener?.cancel()
        }
        switch result {
        case .success(let callback): continuation?.resume(returning: callback)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private static func successPage(success: Bool) -> String {
        let heading = success ? "You're signed in" : "Sign-in failed"
        let detail = success
            ? "You can close this tab and return to Vellum."
            : "Something went wrong. Return to Vellum and try again."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Vellum</title>
        <style>
          html,body{height:100%;margin:0}
          body{display:flex;align-items:center;justify-content:center;
               font-family:-apple-system,BlinkMacSystemFont,'SF Pro',system-ui,sans-serif;
               background:#0b0b0c;color:#f5f5f7}
          .card{text-align:center;max-width:24rem;padding:2rem}
          h1{font-size:1.35rem;margin:0 0 .5rem}
          p{color:#a1a1aa;margin:0;line-height:1.5}
        </style></head>
        <body><div class="card"><h1>\(heading)</h1><p>\(detail)</p></div></body></html>
        """
    }
}
