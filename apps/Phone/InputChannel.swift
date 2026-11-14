import Foundation

/// 到 Mac 的常连接输入通道（WebSocket）。滚动、鼠标、点击、按键走这里：
/// 不用每次新建连接，手指一动 Mac 就能收到。没连上时调用方退回 HTTP。
@MainActor
final class InputChannel {
    static let shared = InputChannel()

    private var task: URLSessionWebSocketTask?
    private(set) var ready = false
    private var connecting = false
    private let session = URLSession(configuration: .ephemeral)

    /// 连上（或正在连）就什么都不做；断了就重连。可以随便多调
    func connectIfNeeded() {
        guard !ready, !connecting else { return }
        let client = BridgeClient.shared
        guard let host = client.activeHost ?? client.candidates.first, let port = Int(client.port) else { return }
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = host
        comps.port = port + 1
        comps.path = "/"
        guard let url = comps.url else { return }

        connecting = true
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        let hello = #"{"t":"hello","token":"\#(client.token)"}"#
        t.send(.string(hello)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                self.connecting = false
                self.ready = error == nil
                if error == nil { self.watch(t) } else { self.task = nil }
            }
        }
    }

    /// 服务器不会主动发消息；receive 返回错误就说明连接断了
    private func watch(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                if case .failure = result {
                    self.ready = false
                    self.task = nil
                } else {
                    self.watch(t)
                }
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        connecting = false
    }

    /// 发一条消息。没连上返回 false（调用方走 HTTP 兜底）
    @discardableResult
    func send(_ json: String) -> Bool {
        guard ready, let t = task else { return false }
        t.send(.string(json)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.task === t else { return }
                self.ready = false
                self.task = nil
            }
        }
        return true
    }
}
