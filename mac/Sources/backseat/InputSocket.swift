import CoreGraphics
import Foundation
import Network

/// 手机的高频输入通道（WebSocket 常连接）：滚动、鼠标、点击、按键。
/// HTTP 每个请求都要新建连接，一秒几十次的触控板事件走这里才跟手。
/// 协议：第一条消息 {"t":"hello","token":…}，之后每条一个 JSON：
///   scroll {dx,dy} 手指拖动，立即滚动 · fling {dx,dy} 松手后的惯性 · mouse {dx,dy} · click {right,state} · key {key}
final class InputSocket: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "backseat.input", qos: .userInteractive)
    private let token: String
    private let log: (String) -> Void

    init(port: UInt16, token: String, log: @escaping (String) -> Void) throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true   // 小包立即发，不攒
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // 局域网广播，手机配对时自动发现这台 Mac。服务名是 Bonjour 主机名，TXT 里带 HTTP 端口（= 本端口 - 1）
        var txt = NWTXTRecord()
        txt["port"] = String(port - 1)
        listener.service = NWListener.Service(name: Bridge.localHostName, type: "_backseat._tcp", txtRecord: txt)
        self.token = token
        self.log = log
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, authed: false)
        }
        listener.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, authed: Bool) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                conn.cancel()
                return
            }
            var ok = authed
            if !ok {
                guard msg["t"] as? String == "hello", msg["token"] as? String == self.token else {
                    conn.cancel()
                    return
                }
                ok = true
                self.log("手机输入通道已连接")
            } else {
                self.handle(msg)
            }
            self.receive(conn, authed: ok)
        }
    }

    private func handle(_ m: [String: Any]) {
        let dx = max(-3000, min(m["dx"] as? Int ?? 0, 3000))
        let dy = max(-3000, min(m["dy"] as? Int ?? 0, 3000))
        switch m["t"] as? String {
        case "scroll":
            DispatchQueue.main.async { Keyboard.scrollDirect(dx: dx, dy: dy) }
        case "fling":
            DispatchQueue.main.async { Keyboard.scroll(dx: dx, dy: dy) }
        case "mouse":
            DispatchQueue.main.async { Keyboard.moveMouse(dx: dx, dy: dy) }
        case "click":
            let right = m["right"] as? Bool ?? false
            let state = m["state"] as? Int ?? 1
            // 记下点击时系统的修饰键状态，方便排查「单击变右键」
            let held = CGEventSource.flagsState(.combinedSessionState)
            var mods: [String] = []
            if held.contains(.maskControl) { mods.append("Control") }
            if held.contains(.maskCommand) { mods.append("Command") }
            if held.contains(.maskShift) { mods.append("Shift") }
            if held.contains(.maskAlternate) { mods.append("Option") }
            self.log("点击：\(right ? "右键" : "左键")\(state == 2 ? "（双击）" : "")，系统修饰键：\(mods.isEmpty ? "无" : mods.joined(separator: "+"))")
            DispatchQueue.main.async { Keyboard.click(right: right, state: state) }
        case "open":
            // 只允许打开这两个系统界面：调度中心、应用程序（原来的启动台）
            guard let app = m["app"] as? String, ["Mission Control", "Apps"].contains(app) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app]
            try? p.run()
        case "zoom":
            let d = max(-400, min(m["d"] as? Int ?? 0, 400))
            DispatchQueue.main.async { Keyboard.zoom(d) }
        case "down":
            DispatchQueue.main.async { Keyboard.mouseButton(down: true) }
        case "up":
            DispatchQueue.main.async { Keyboard.mouseButton(down: false) }
        case "key":
            guard let key = m["key"] as? String else { return }
            DispatchQueue.main.async {
                if ["enter", "backspace", "cmd+a", "shift+enter", "cmd+enter"].contains(key) { Focus.ensureInput() }
                Keyboard.press(key)
            }
        default:
            break
        }
    }
}
