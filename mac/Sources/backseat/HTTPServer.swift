import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let isLoopback: Bool
    let peer: String

    func json() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// 一次请求的应答句柄。可以立即回复，也可以挂起（长轮询 / 等待审批）稍后回复。
final class HTTPResponder: @unchecked Sendable {
    private let connection: NWConnection
    private var done = false
    private let lock = NSLock()
    /// 对端提前断开时回调（比如 hook 被 Claude Code 杀掉）
    var onClose: (() -> Void)?

    init(connection: NWConnection) { self.connection = connection }

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }

    func send(_ status: Int = 200, json: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data("{}".utf8)
        send(status, body: data, contentType: "application/json")
    }

    func send(_ status: Int, body: Data, contentType: String = "text/plain") {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType); charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    fileprivate func markClosed() {
        lock.lock()
        let wasDone = done
        done = true
        lock.unlock()
        if !wasDone { onClose?() }
    }
}

final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "backseat.http")
    private let handler: (HTTPRequest, HTTPResponder) -> Void

    init(port: UInt16, handler: @escaping (HTTPRequest, HTTPResponder) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                FileHandle.standardError.write(Data("监听失败: \(err)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf, conn: conn) {
                let responder = HTTPResponder(connection: conn)
                self.watchForClose(conn, responder: responder)
                self.handler(req, responder)
                return
            }
            if isComplete || error != nil || buf.count > 4 << 20 { conn.cancel(); return }
            self.read(conn, buffer: buf)
        }
    }

    /// 请求读完后继续读：读到 EOF/错误 说明客户端走了。
    private func watchForClose(_ conn: NWConnection, responder: HTTPResponder) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil || data == nil {
                responder.markClosed()
            } else {
                self?.watchForClose(conn, responder: responder)
            }
        }
    }

    private static func parse(_ buf: Data, conn: NWConnection) -> HTTPRequest? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[..<sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            headers[line[..<idx].lowercased()] = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard buf.count - bodyStart >= length else { return nil }
        let body = buf[bodyStart..<(bodyStart + length)]

        let target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }

        var loopback = false
        var peer = "?"
        if case .hostPort(let host, _) = conn.endpoint {
            peer = "\(host)"
            loopback = peer == "127.0.0.1" || peer == "::1" || peer.hasPrefix("::ffff:127.")
        }
        return HTTPRequest(method: String(first[0]), path: comps?.path ?? target, query: query,
                           headers: headers, body: Data(body), isLoopback: loopback, peer: peer)
    }
}
