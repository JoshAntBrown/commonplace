import Foundation
import Network

/// A Model Context Protocol server inside the app (Streamable HTTP transport),
/// so agents work on the live boards rather than editing files behind the
/// app's back. Listens on 127.0.0.1 only; every request needs the bearer
/// token, and requests from web pages (a foreign Origin) are refused.
final class MCPServer {
    static let defaultPort: UInt16 = 7717
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let port: UInt16
    let token: String
    private let tools: MCPTools
    private let queue = DispatchQueue(label: "commonplace.mcp")
    private var listener: NWListener?
    private(set) var isRunning = false

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    var claudeCodeCommand: String {
        "claude mcp add --transport http commonplace \(url) --header \"Authorization: Bearer \(token)\""
    }

    init(library: Library) {
        let saved = UserDefaults.standard.integer(forKey: "mcpPort")
        port = saved > 0 && saved < 65536 ? UInt16(saved) : Self.defaultPort
        token = Self.loadToken(in: library.root)
        tools = MCPTools(library: library)
    }

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.isRunning = true
                case .failed(let error):
                    NSLog("Commonplace MCP server failed: \(error)")
                    self?.isRunning = false
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Commonplace MCP server could not start: \(error)")
        }
    }

    /// A random secret kept in the library, readable only by this user.
    private static func loadToken(in root: URL) -> String {
        let file = root.appendingPathComponent(".mcp-token")
        if let existing = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }

    // MARK: HTTP

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.handle(request, on: connection)
            } else if done || error != nil || buffer.count > 16 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Parses a complete HTTP/1.1 request, or returns nil if more bytes are needed.
    private static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        guard request.path.split(separator: "?").first == "/mcp" else {
            return send(connection, status: 404, json: ["error": "not found"])
        }
        // Only this machine, and never a web page: guards against DNS rebinding
        // and drive-by requests from sites open in a browser.
        let host = request.headers["host"] ?? ""
        let hostName = host.split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost"].contains(hostName) else {
            return send(connection, status: 403, json: ["error": "forbidden host"])
        }
        if let origin = request.headers["origin"], origin != "null",
           !(origin.hasPrefix("http://127.0.0.1") || origin.hasPrefix("http://localhost")) {
            return send(connection, status: 403, json: ["error": "forbidden origin"])
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return send(connection, status: 401, json: ["error": "missing or invalid token"])
        }
        guard request.method == "POST" else {
            // No server-initiated stream; everything is request/response.
            return send(connection, status: 405, json: ["error": "use POST"], headers: ["Allow": "POST"])
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = message["method"] as? String else {
            return send(connection, status: 400, json: Self.error(nil, -32700, "parse error"))
        }
        guard let id = message["id"] else {
            // A notification (e.g. notifications/initialized): nothing to return.
            return send(connection, status: 202, json: nil)
        }
        let params = message["params"] as? [String: Any] ?? [:]
        DispatchQueue.main.async {
            self.dispatch(method, params: params) { result in
                self.queue.async {
                    switch result {
                    case .success(let value):
                        self.send(connection, status: 200, json: ["jsonrpc": "2.0", "id": id, "result": value])
                    case .failure(let error):
                        self.send(connection, status: 200, json: Self.error(id, error.code, error.message))
                    }
                }
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, json: Any?, headers: [String: String] = [:]) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: JSON-RPC

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    private func dispatch(_ method: String, params: [String: Any],
                          reply: @escaping (Result<Any, RPCError>) -> Void) {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            reply(.success([
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "commonplace", "version": "0.1.0"],
                "instructions": MCPTools.instructions,
            ]))
        case "ping":
            reply(.success([String: Any]()))
        case "tools/list":
            reply(.success(["tools": MCPTools.definitions]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return reply(.failure(RPCError(code: -32602, message: "missing tool name")))
            }
            tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:]) { outcome in
                switch outcome {
                case .success(let value):
                    reply(.success(["content": [["type": "text", "text": Self.text(value)]], "isError": false]))
                case .failure(let error):
                    reply(.success(["content": [["type": "text", "text": error.message]], "isError": true]))
                }
            }
        default:
            reply(.failure(RPCError(code: -32601, message: "method not found: \(method)")))
        }
    }

    private static func text(_ value: Any) -> String {
        if let s = value as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
