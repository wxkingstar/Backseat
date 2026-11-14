import Foundation
import SystemConfiguration

/// 全部状态都在 queue 上串行访问。
final class Bridge: @unchecked Sendable {
    struct Event {
        let id: Int
        let kind: String      // done | idle | approval | resolved | prompt | info
        let title: String
        let body: String
        let project: String
        let ts: Date
    }

    final class Approval {
        let id: String
        let tool: String
        let title: String
        let detail: String
        let project: String
        let ts = Date()
        let responder: HTTPResponder
        init(id: String, tool: String, title: String, detail: String, project: String, responder: HTTPResponder) {
            self.id = id; self.tool = tool; self.title = title; self.detail = detail
            self.project = project; self.responder = responder
        }
    }

    struct Session { var project: String; var working: Bool; var since: Date }

    private let queue = DispatchQueue(label: "backseat.state")
    private let token: String
    private let mic = MicStream()
    private var seq = 0
    private var events: [Event] = []
    private var approvals: [Approval] = []
    private var sessions: [String: Session] = [:]
    private var waiters: [(since: Int, responder: HTTPResponder)] = []
    private var remote = false
    private var lastWatchSeen = Date.distantPast
    /// 配对码（4 位，只在局域网里用）：手表 / 手机第一次连接时输入，换取 token。连错 5 次就换一个。
    private(set) var pairCode = Bridge.newPairCode()
    private var pairFailures = 0
    private let port: UInt16

    /// 遥控模式下，审批最多等手表这么久，超时交还给电脑
    private let approvalTimeout: TimeInterval = 280

    init(token: String, port: UInt16) { self.token = token; self.port = port }

    private static func newPairCode() -> String { String(format: "%04d", Int.random(in: 0..<10_000)) }

    /// 本机的 Bonjour 主机名（不带 .local）。ProcessInfo.hostName 有时返回的不是它，所以直接问系统配置
    static var localHostName: String? { SCDynamicStoreCopyLocalHostName(nil) as String? }

    /// 本机可达的地址：Bonjour 名 + 局域网 IPv4，配对成功后交给客户端保存
    static var hosts: [String] {
        var list: [String] = []
        if let name = localHostName { list.append("\(name).local") }
        // 不用 Host.current().addresses：它会做反向解析，可能卡好几秒
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return list }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let i = p {
            p = i.pointee.ifa_next
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  i.pointee.ifa_flags & UInt32(IFF_UP) != 0, i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: buf)
            if !ip.hasPrefix("169.254."), !list.contains(ip) { list.append(ip) }
        }
        return list
    }

    private func pair(_ req: HTTPRequest, _ res: HTTPResponder) {
        guard req.json()["code"] as? String == pairCode else {
            pairFailures += 1
            log("拒绝 \(req.peer)：配对码不对")
            if pairFailures >= 5 {
                pairFailures = 0
                pairCode = Self.newPairCode()
                log("配对码连续输错，已更换。新配对码：\(pairCode)")
            }
            return res.send(403, json: ["error": "配对码不对"])
        }
        pairFailures = 0
        log("已配对（\(req.peer)）")
        res.send(json: ["ok": true, "token": token, "hosts": Self.hosts, "port": Int(port),
                        "name": Host.current().localizedName ?? "Mac"])
    }

    // MARK: - 路由

    func handle(_ req: HTTPRequest, _ res: HTTPResponder) {
        queue.async { self.route(req, res) }
    }

    private func route(_ req: HTTPRequest, _ res: HTTPResponder) {
        if req.path.hasPrefix("/hook/") {
            guard req.isLoopback else { return res.send(403, json: ["error": "loopback only"]) }
            return hook(String(req.path.dropFirst(6)), req.json(), res)
        }
        if req.method == "POST", req.path == "/pair" { return pair(req, res) }
        if req.path == "/ping" { return res.send(json: ["ok": true, "name": Host.current().localizedName ?? "Mac"]) }

        let given = req.headers["x-backseat-token"] ?? req.query["token"] ?? ""
        guard given == token else {
            log("拒绝 \(req.peer)：token 不对（需要在 App 里重新配对）")
            return res.send(401, json: ["error": "bad token"])
        }
        if Date().timeIntervalSince(lastWatchSeen) > 60 { log("手表已连接（\(req.peer)）") }
        lastWatchSeen = Date()

        switch (req.method, req.path) {
        case ("GET", "/api/state"):
            let since = Int(req.query["since"] ?? "") ?? -1
            let wait = min(Double(req.query["wait"] ?? "0") ?? 0, 30)
            if since >= seq && wait > 0 {
                waiters.append((since, res))
                queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self else { return }
                    self.waiters.removeAll { $0.responder === res }
                    res.send(json: self.snapshot(since: since))
                }
            } else {
                res.send(json: snapshot(since: since))
            }

        case ("POST", "/api/mode"):
            remote = req.json()["remote"] as? Bool ?? false
            log(remote ? "手表进入遥控模式" : "手表退出遥控模式")
            if !remote { releaseAll() }
            bump()
            res.send(json: ["remote": remote])

        case ("POST", "/api/approval"):
            let body = req.json()
            let id = body["id"] as? String ?? ""
            let decision = body["decision"] as? String ?? "terminal"
            guard let idx = approvals.firstIndex(where: { $0.id == id }) else {
                return res.send(404, json: ["error": "已处理或已过期"])
            }
            let a = approvals.remove(at: idx)
            resolve(a, decision: decision)
            res.send(json: ["ok": true])

        case ("POST", "/api/prompt"):
            let body = req.json()
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return res.send(400, json: ["error": "空内容"]) }
            let submit = body["submit"] as? Bool ?? true
            let target = Keyboard.frontAppName
            DispatchQueue.main.async { _ = Focus.ensureInput(); Keyboard.paste(text, submit: submit) }
            log("输入 → \(target): \(text)")
            res.send(json: ["ok": true, "target": target])

        case ("POST", "/api/mic/start"):
            // 手表开始按住说话：输入法模式下开虚拟麦克风并按下语音快捷键
            let id = req.json()["id"] as? String ?? UUID().uuidString
            do {
                let engine = try mic.start(id: id)
                log("开始说话（\(engine == .ime ? MicStream.imeName : "Mac 内置识别")）→ \(Keyboard.frontAppName)，\(mic.focusNote)")
                res.send(json: ["ok": true, "engine": engine.rawValue, "target": Keyboard.frontAppName])
            } catch {
                log("虚拟麦克风启动失败：\(error.localizedDescription)")
                res.send(500, json: ["error": "麦克风启动失败"])
            }

        case ("POST", "/api/mic/chunk"):
            mic.append(id: req.query["id"] ?? "", seq: Int(req.query["seq"] ?? "") ?? 0, pcm: req.body)
            res.send(json: ["ok": true])

        case ("POST", "/api/mic/end"):
            let body = req.json()
            let id = body["id"] as? String ?? ""
            let lastSeq = body["lastSeq"] as? Int ?? -1
            let submit = body["submit"] as? Bool ?? true
            let cancel = body["cancel"] as? Bool ?? false
            if let diag = body["diag"] as? String, !diag.isEmpty { log("诊断：\(diag)") }
            Task {
                let (engine, text) = await self.mic.finish(id: id, lastSeq: lastSeq, submit: submit, cancel: cancel)
                let target = await MainActor.run { Keyboard.frontAppName }
                if cancel {
                    self.log("取消说话：\(self.mic.cancelNote)；\(self.mic.audioNote)")
                } else if engine == .ime {
                    self.log("\(MicStream.imeName)上屏 → \(target)；\(self.mic.audioNote)")
                } else {
                    self.log("语音 → \(target): \(text ?? "")")
                }
                if engine == .apple && !cancel && (text ?? "").isEmpty {
                    return res.send(422, json: ["error": "没听清，再说一次"])
                }
                res.send(json: ["ok": true, "engine": engine.rawValue, "text": text ?? "", "target": target])
            }

        case ("POST", "/api/scroll"):
            let body = req.json()
            let dy = max(-3000, min(body["dy"] as? Int ?? 0, 3000))
            let dx = max(-3000, min(body["dx"] as? Int ?? 0, 3000))
            DispatchQueue.main.async { Keyboard.scroll(dx: dx, dy: dy) }
            res.send(json: ["ok": true])

        case ("POST", "/api/log"):
            log("📱 " + (req.json()["text"] as? String ?? ""))
            res.send(json: ["ok": true])

        case ("POST", "/api/mouse"):
            let body = req.json()
            let dx = max(-2000, min(body["dx"] as? Int ?? 0, 2000))
            let dy = max(-2000, min(body["dy"] as? Int ?? 0, 2000))
            DispatchQueue.main.async { Keyboard.moveMouse(dx: dx, dy: dy) }
            res.send(json: ["ok": true])

        case ("POST", "/api/click"):
            let body = req.json()
            let right = body["button"] as? String == "right"
            let state = body["state"] as? Int ?? 1
            DispatchQueue.main.async { Keyboard.click(right: right, state: state) }
            res.send(json: ["ok": true])

        case ("GET", "/api/apps"):
            // 正在运行的普通应用，给手机的「目标应用」设置用
            let (apps, target) = DispatchQueue.main.sync { (Focus.runningApps(), Focus.targetBundleID) }
            res.send(json: ["apps": apps, "target": target])

        case ("POST", "/api/target"):
            let bundle = req.json()["bundle"] as? String ?? ""
            DispatchQueue.main.async { Focus.targetBundleID = bundle }
            log(bundle.isEmpty ? "目标应用：跟随前台应用" : "目标应用：\(bundle)")
            res.send(json: ["ok": true])

        case ("GET", "/api/input"):
            // 读出当前输入框的全部文字（手机松手后预览用）
            let text = DispatchQueue.main.sync { Focus.focusedText() }
            res.send(json: ["ok": text != nil, "text": text ?? ""])

        case ("POST", "/api/input"):
            // 用手机上改好的文字替换输入框内容；submit = true 时随后回车发送
            let body = req.json()
            let text = body["text"] as? String ?? ""
            let submit = body["submit"] as? Bool ?? false
            DispatchQueue.main.async {
                let note = Focus.ensureInput()
                if Focus.focusedText() != text {
                    _ = Keyboard.press("cmd+a")
                    if text.isEmpty { _ = Keyboard.press("backspace") } else { Keyboard.paste(text, submit: false) }
                }
                if submit {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { _ = Keyboard.press("enter") }
                }
                self.log("\(submit ? "发送" : "同步")输入框（\(text.count) 字），\(note)")
            }
            res.send(json: ["ok": true])

        case ("POST", "/api/key"):
            let key = req.json()["key"] as? String ?? ""
            let count = max(1, min(req.json()["count"] as? Int ?? 1, 20))
            log("按键 \(key)\(count > 1 ? " ×\(count)" : "") → \(Keyboard.frontAppName)")
            DispatchQueue.main.async {
                // 编辑输入框的键先确保光标在输入框里
                if ["enter", "backspace", "cmd+a", "shift+enter", "cmd+enter"].contains(key) { Focus.ensureInput() }
                for _ in 0..<count { Keyboard.press(key) }
            }
            res.send(json: ["ok": true])

        default:
            res.send(404, json: ["error": "not found"])
        }
    }

    // MARK: - Claude Code hooks

    private func hook(_ name: String, _ input: [String: Any], _ res: HTTPResponder) {
        let sid = input["session_id"] as? String ?? "?"
        let cwd = input["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude" : (cwd as NSString).lastPathComponent

        switch name {
        case "UserPromptSubmit":
            sessions[sid] = Session(project: project, working: true, since: Date())
            bump()
            res.send(json: [:])

        case "Stop":
            sessions[sid] = Session(project: project, working: false, since: Date())
            let msg = (input["last_assistant_message"] as? String) ?? Self.lastAssistantText(input["transcript_path"] as? String)
            push("done", title: "完成", body: Self.clip(msg ?? "这一轮结束了", 400), project: project)
            res.send(json: [:])

        case "Notification":
            let type = input["notification_type"] as? String ?? ""
            let message = input["message"] as? String ?? ""
            // 权限请求已由 PermissionRequest 单独处理；这里只关心「在等你」
            if type == "idle_prompt" || type == "agent_needs_input" || type == "elicitation_dialog" {
                push("idle", title: "等你回复", body: Self.clip(message, 200), project: project)
            }
            res.send(json: [:])

        case "SessionEnd":
            sessions[sid] = nil
            bump()
            res.send(json: [:])

        case "PermissionRequest":
            let tool = input["tool_name"] as? String ?? "Tool"
            let (title, detail) = Self.describe(tool: tool, input: input["tool_input"] as? [String: Any] ?? [:])
            let watchAlive = Date().timeIntervalSince(lastWatchSeen) < 45
            guard remote && watchAlive else {
                // 不在遥控模式：只轻提醒，审批照常在电脑上做
                push("info", title: "需要审批（电脑上）", body: "\(title)\n\(detail)", project: project)
                return res.send(json: [:])
            }
            let a = Approval(id: UUID().uuidString, tool: tool, title: title, detail: detail,
                             project: project, responder: res)
            approvals.append(a)
            log("待审批 [\(project)] \(title): \(detail)")
            res.onClose = { [weak self] in
                // hook 被取消（比如你在电脑上已经点了），撤掉这张卡片
                self?.queue.async {
                    guard let self, let i = self.approvals.firstIndex(where: { $0 === a }) else { return }
                    self.approvals.remove(at: i)
                    self.push("resolved", title: "已在电脑上处理", body: title, project: project)
                }
            }
            push("approval", title: title, body: detail, project: project)
            queue.asyncAfter(deadline: .now() + approvalTimeout) { [weak self] in
                guard let self, let i = self.approvals.firstIndex(where: { $0 === a }) else { return }
                self.approvals.remove(at: i)
                self.resolve(a, decision: "terminal")
            }

        default:
            res.send(json: [:])
        }
    }

    private func resolve(_ a: Approval, decision: String) {
        let out: [String: Any]
        switch decision {
        case "allow":
            out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        case "deny":
            out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                          "decision": ["behavior": "deny", "message": "用户在手表上拒绝了这个操作"]]]
        default:
            out = [:] // 交还给电脑上的权限对话框
        }
        a.responder.send(json: out)
        let label = ["allow": "已允许", "deny": "已拒绝"][decision] ?? "转到电脑"
        log("\(label) [\(a.project)] \(a.title)")
        push("resolved", title: label, body: a.title, project: a.project)
    }

    private func releaseAll() {
        let all = approvals
        approvals.removeAll()
        all.forEach { resolve($0, decision: "terminal") }
    }

    // MARK: - 事件 / 快照

    private func push(_ kind: String, title: String, body: String, project: String) {
        seq += 1
        events.append(Event(id: seq, kind: kind, title: title, body: body, project: project, ts: Date()))
        if events.count > 50 { events.removeFirst(events.count - 50) }
        flush()
    }

    private func bump() { seq += 1; flush() }

    private func flush() {
        let ws = waiters
        waiters.removeAll()
        for w in ws { w.responder.send(json: snapshot(since: w.since)) }
    }

    private func snapshot(since: Int) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let newEvents = events.filter { $0.id > since }.suffix(20).map {
            ["id": $0.id, "kind": $0.kind, "title": $0.title, "body": $0.body,
             "project": $0.project, "ts": iso.string(from: $0.ts)] as [String: Any]
        }
        let pend = approvals.map {
            ["id": $0.id, "tool": $0.tool, "title": $0.title, "detail": $0.detail,
             "project": $0.project, "ts": iso.string(from: $0.ts)] as [String: Any]
        }
        let sess = sessions.values.sorted { $0.since > $1.since }.map {
            ["project": $0.project, "working": $0.working, "since": iso.string(from: $0.since)] as [String: Any]
        }
        return ["seq": seq, "remote": remote, "frontApp": Keyboard.frontAppName,
                "pending": pend, "events": Array(newEvents), "sessions": sess]
    }

    // MARK: - 工具

    func log(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(t)] \(s)")
        fflush(stdout)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    static func describe(tool: String, input: [String: Any]) -> (String, String) {
        func file(_ k: String = "file_path") -> String { ((input[k] as? String) ?? "") }
        switch tool {
        case "Bash":
            return ("运行命令", clip(input["command"] as? String ?? "", 600))
        case "Edit", "MultiEdit":
            return ("修改 \((file() as NSString).lastPathComponent)", file())
        case "Write":
            return ("写入 \((file() as NSString).lastPathComponent)", file())
        case "NotebookEdit":
            return ("修改 Notebook", file("notebook_path"))
        case "WebFetch":
            return ("访问网页", input["url"] as? String ?? "")
        case "WebSearch":
            return ("搜索", input["query"] as? String ?? "")
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
            return (tool, clip(String(data: data, encoding: .utf8) ?? "", 400))
        }
    }

    /// 老版本 Stop hook 没有 last_assistant_message 时，从 transcript 末尾取最后一条助手文本
    static func lastAssistantText(_ path: String?) -> String? {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }
}
