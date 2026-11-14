import Foundation

enum BridgeError: LocalizedError {
    case noHost, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .noHost: return "连不上 Mac"
        case .http(let code, let msg): return msg.isEmpty ? "HTTP \(code)" : msg
        }
    }
}

/// 和 Mac 上 backseat 通讯。依次尝试候选地址，记住能通的那个。
final class BridgeClient: @unchecked Sendable {
    static let shared = BridgeClient()

    private let lock = NSLock()
    private var _active: String?
    private var _token = Keychain.get("token") ?? ""
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 40
        c.waitsForConnectivity = false
        // 长轮询占一条连接，说话时的音频分片还要并发上传
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    /// 配对时从 Mac 拿到的 token（存在钥匙串里）
    var token: String { lock.lock(); defer { lock.unlock() }; return _token }
    var port: String { UserDefaults.standard.string(forKey: "pairedPort") ?? "8787" }

    /// 用 Mac 上显示的配对码换 token，并记下 Mac 的地址
    func pair(host: String, port: String, code: String) async throws {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = Int(port)
        comps.path = "/pair"
        guard let url = comps.url else { throw BridgeError.noHost }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let token = obj["token"] as? String else {
            throw BridgeError.http(status, obj["error"] as? String ?? "")
        }
        var hosts = (obj["hosts"] as? [String] ?? []).filter { $0 != host }
        hosts.insert(host, at: 0)
        Keychain.set("token", token)
        UserDefaults.standard.set(hosts, forKey: "pairedHosts")
        UserDefaults.standard.set(String(obj["port"] as? Int ?? Int(port) ?? 8787), forKey: "pairedPort")
        lock.lock(); _token = token; lock.unlock()
        activeHost = host
    }

    /// 当前的配对信息，用来传给自己的另一台设备；没配对时为 nil
    var pairingInfo: [String: Any]? {
        let t = token
        guard !t.isEmpty else { return nil }
        return ["token": t, "hosts": UserDefaults.standard.stringArray(forKey: "pairedHosts") ?? [], "port": port]
    }

    /// 采用另一台设备传来的配对信息。和现在的一样、或内容不完整时返回 false
    func adopt(_ info: [String: Any]) -> Bool {
        guard let t = info["token"] as? String, !t.isEmpty, t != token,
              let hosts = info["hosts"] as? [String], !hosts.isEmpty else { return false }
        Keychain.set("token", t)
        UserDefaults.standard.set(hosts, forKey: "pairedHosts")
        UserDefaults.standard.set(info["port"] as? String ?? "8787", forKey: "pairedPort")
        UserDefaults.standard.removeObject(forKey: "lastGoodHost")
        lock.lock(); _token = t; _active = nil; lock.unlock()
        return true
    }

    func unpair() {
        Keychain.set("token", nil)
        for k in ["pairedHosts", "pairedPort", "lastGoodHost"] { UserDefaults.standard.removeObject(forKey: k) }
        lock.lock(); _token = ""; _active = nil; lock.unlock()
    }

    /// 尝试顺序：手填地址 → 上次连通的地址 → 配对时拿到的 IP → Bonjour 名（.local 解析慢，放最后）
    var candidates: [String] {
        var list: [String] = []
        func add(_ h: String?) { if let h, !h.isEmpty, !list.contains(h) { list.append(h) } }
        add(UserDefaults.standard.string(forKey: "customHost"))
        add(UserDefaults.standard.string(forKey: "lastGoodHost"))
        let built = UserDefaults.standard.stringArray(forKey: "pairedHosts") ?? []
        built.filter { !$0.hasSuffix(".local") }.forEach(add)
        built.filter { $0.hasSuffix(".local") }.forEach(add)
        return list
    }

    var activeHost: String? {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set {
            lock.lock(); _active = newValue; lock.unlock()
            if let newValue { UserDefaults.standard.set(newValue, forKey: "lastGoodHost") }
        }
    }

    /// race = true：所有候选地址同时发，谁先回用谁（打开 App 时最快连上）。只用于幂等的 GET。
    func call(_ method: String, _ path: String, query: [String: String] = [:],
              body: [String: Any]? = nil, raw: Data? = nil,
              timeout: TimeInterval = 8, race: Bool = false) async throws -> [String: Any] {
        if race, candidates.count > 1 {
            return try await raceCall(method, path, query: query, timeout: timeout)
        }
        var hosts = candidates
        if let a = activeHost, let i = hosts.firstIndex(of: a) { hosts.remove(at: i); hosts.insert(a, at: 0) }
        guard !hosts.isEmpty else { throw BridgeError.noHost }

        var lastError: Error = BridgeError.noHost
        for (i, host) in hosts.enumerated() {
            var comps = URLComponents()
            comps.scheme = "http"
            comps.host = host
            comps.port = Int(port)
            comps.path = path
            if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue(token, forHTTPHeaderField: "X-Backseat-Token")
            // 当前可用地址给足超时；探测其他地址时快速失败
            req.timeoutInterval = (i == 0 && host == activeHost) ? timeout : min(timeout, 3)
            if let body {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if let raw {
                req.httpBody = raw
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                activeHost = host
                guard (200..<300).contains(code) else { throw BridgeError.http(code, obj["error"] as? String ?? "") }
                return obj
            } catch let e as BridgeError {
                throw e // 服务器已响应，不再换地址
            } catch {
                if host == activeHost { activeHost = nil }
                lastError = error
            }
        }
        throw lastError
    }

    private func raceCall(_ method: String, _ path: String, query: [String: String],
                          timeout: TimeInterval) async throws -> [String: Any] {
        let hosts = candidates
        return try await withThrowingTaskGroup(of: (String, [String: Any]).self) { group in
            for h in hosts {
                group.addTask { (h, try await self.request(host: h, method, path, query: query, timeout: timeout)) }
            }
            var lastError: Error = BridgeError.noHost
            while let next = await group.nextResult() {
                switch next {
                case .success(let (host, obj)):
                    activeHost = host
                    group.cancelAll()
                    return obj
                case .failure(let e):
                    if e is BridgeError { group.cancelAll(); throw e }
                    lastError = e
                }
            }
            throw lastError
        }
    }

    private func request(host: String, _ method: String, _ path: String, query: [String: String],
                         timeout: TimeInterval) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = Int(port)
        comps.path = path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw BridgeError.noHost }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Backseat-Token")
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else { throw BridgeError.http(code, obj["error"] as? String ?? "") }
        return obj
    }

    // MARK: - 便捷方法

    func sendPrompt(_ text: String, submit: Bool) async throws -> String {
        let r = try await call("POST", "/api/prompt", body: ["text": text, "submit": submit])
        return r["target"] as? String ?? "Mac"
    }

    // MARK: - 手表当麦克风

    /// 开始说话，返回 Mac 用的识别引擎（ime / apple）
    func micStart(id: String) async throws -> String {
        let r = try await call("POST", "/api/mic/start", body: ["id": id], timeout: 5)
        return r["engine"] as? String ?? "apple"
    }

    func micChunk(id: String, seq: Int, pcm: Data) async throws {
        _ = try await call("POST", "/api/mic/chunk", query: ["id": id, "seq": "\(seq)"], raw: pcm, timeout: 5)
    }

    /// 结束说话，返回 (引擎, 识别文字)。输入法模式由输入法直接上屏，文字为空。
    func micEnd(id: String, lastSeq: Int, submit: Bool, cancel: Bool, diag: String = "") async throws -> (String, String) {
        let r = try await call("POST", "/api/mic/end",
                               body: ["id": id, "lastSeq": lastSeq, "submit": submit, "cancel": cancel, "diag": diag],
                               timeout: 30)
        return (r["engine"] as? String ?? "apple", r["text"] as? String ?? "")
    }

    func press(_ key: String, count: Int = 1) async throws {
        _ = try await call("POST", "/api/key", body: ["key": key, "count": count], timeout: 4)
    }

    /// 鼠标滚轮，dy > 0 页面往下滚
    func scroll(dx: Int = 0, dy: Int) async throws {
        _ = try await call("POST", "/api/scroll", body: ["dx": dx, "dy": dy], timeout: 3)
    }

    /// 鼠标模式：相对移动指针
    func moveMouse(dx: Int, dy: Int) async throws {
        _ = try await call("POST", "/api/mouse", body: ["dx": dx, "dy": dy], timeout: 3)
    }

    /// 鼠标点击；state = 2 为双击的第二下
    func click(right: Bool, state: Int = 1) async throws {
        _ = try await call("POST", "/api/click", body: ["button": right ? "right" : "left", "state": state], timeout: 3)
    }

    /// 读出 Mac 当前输入框的全部文字
    /// 返回 nil 表示这个应用读不出输入框文字（比如终端里的 Codex）
    func inputText() async throws -> String? {
        let r = try await call("GET", "/api/input", timeout: 4)
        guard r["ok"] as? Bool == true else { return nil }
        return r["text"] as? String ?? ""
    }

    /// Mac 上正在运行的应用，以及当前选定的目标应用（空 = 跟随前台）
    func apps() async throws -> (apps: [(name: String, bundle: String)], target: String) {
        let r = try await call("GET", "/api/apps", timeout: 4)
        let list = (r["apps"] as? [[String: String]] ?? []).map { (name: $0["name"] ?? "", bundle: $0["bundle"] ?? "") }
        return (list, r["target"] as? String ?? "")
    }

    func setTarget(bundle: String) async throws {
        _ = try await call("POST", "/api/target", body: ["bundle": bundle], timeout: 4)
    }

    /// 用这段文字替换 Mac 输入框内容；submit = true 时随后回车发送
    func setInput(_ text: String, submit: Bool) async throws {
        _ = try await call("POST", "/api/input", body: ["text": text, "submit": submit], timeout: 5)
    }

    func decide(_ id: String, _ decision: String) async throws {
        _ = try await call("POST", "/api/approval", body: ["id": id, "decision": decision])
    }

    func setRemote(_ on: Bool) async throws {
        _ = try await call("POST", "/api/mode", body: ["remote": on])
    }
}
