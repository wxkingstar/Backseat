import Foundation
import Observation
import WatchKit

struct Approval: Identifiable, Equatable {
    let id: String
    let tool: String
    let title: String
    let detail: String
    let project: String

    /// 看起来危险的命令：不允许双指互点直接放行
    var isRisky: Bool {
        let d = detail.lowercased()
        return ["rm -rf", "rm -fr", "git push", "--force", "reset --hard", "drop table", "sudo ",
                "chmod -r", "mkfs", "> /dev/", "git clean", "kubectl delete", "terraform apply"]
            .contains { d.contains($0) }
    }
}

struct FeedItem: Identifiable {
    let id: Int
    let kind: String
    let title: String
    let body: String
    let project: String
    let ts: Date
}

struct WorkSession: Identifiable {
    var id: String { project + since.description }
    let project: String
    let working: Bool
    let since: Date
}

@MainActor @Observable
final class Store {
    static let shared = Store()

    /// 乐观连接：最近 30 分钟内连通过，打开 App 就直接按已连接显示、按钮可用，
    /// 后台立即校验，连续失败两次才显示断线。局域网里不用每次都等「连接中」。
    var connected = Store.recentlyConnected
    var everConnected = Store.recentlyConnected
    private var loadedOnce = false

    private static var recentlyConnected: Bool {
        let t = UserDefaults.standard.double(forKey: "lastConnectedAt")
        return t > 0 && Date().timeIntervalSince1970 - t < 30 * 60
    }
    var frontApp = ""
    var remote = false           // Mac 端确认的遥控状态
    var remoteBusy = false       // 正在切换
    var pending: [Approval] = []
    var feed: [FeedItem] = []
    var sessions: [WorkSession] = []
    var toast: String?
    /// Action Button 每按一次加 1，主页据此开始 / 结束说话
    var talkToggle = 0
    /// 侧键在 App 还没启动时按下：界面出来后要补上这次「开始说话」
    var talkPending = false
    var lastError: String?

    /// 按键页直接摆出来的键；其余的收在「所有按键」里。在手表设置里选
    var keys: [SideKeyKind] = SideKeyKind.load("watchKeys", fallback: SideKeyKind.watchDefaults) {
        didSet { SideKeyKind.save(keys, "watchKeys") }
    }

    /// 按下一个键
    func run(_ k: SideKeyKind) {
        if let t = k.text { insert(t) } else if let key = k.key { press(key) }
    }

    var autoSubmit: Bool {
        get { UserDefaults.standard.object(forKey: "autoSubmit") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSubmit") }
    }

    var working: WorkSession? { sessions.first { $0.working } }

    private let client = BridgeClient.shared
    private let keepAlive = RemoteSession()
    private var seq = -1
    private var pollTask: Task<Void, Never>?
    private let iso = ISO8601DateFormatter()

    // MARK: - 轮询

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var failures = 0
            var quick = true // 每次（重新）开始先发一个不挂起的短请求，马上拿到最新状态
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let long = !quick && self.connected
                    let r = try await self.client.call("GET", "/api/state",
                                                       query: ["since": "\(self.seq)", "wait": long ? "25" : "0"],
                                                       timeout: long ? 35 : 3, race: !long)
                    self.apply(r)
                    failures = 0
                    quick = false
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    self.lastError = error.localizedDescription
                    // 偶尔一次失败（抬腕时网络还没醒、Wi-Fi 切换）不算断线，连续失败才显示
                    if failures >= 2 && self.connected {
                        WKInterfaceDevice.current().play(.failure)
                        self.connected = false
                    }
                    // 快速重试：0.3s、1s、2s，之后每 3s
                    let delays = [0.3, 1.0, 2.0]
                    try? await Task.sleep(for: .seconds(failures <= delays.count ? delays[failures - 1] : 3))
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 回到前台时立刻刷新一次（长轮询可能正挂着）
    func refreshNow() {
        stopPolling()
        startPolling()
    }

    private func apply(_ r: [String: Any]) {
        let first = !loadedOnce
        loadedOnce = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastConnectedAt")
        connected = true
        everConnected = true
        lastError = nil
        frontApp = r["frontApp"] as? String ?? ""
        remote = r["remote"] as? Bool ?? false

        let newPending = (r["pending"] as? [[String: Any]] ?? []).map {
            Approval(id: $0["id"] as? String ?? "", tool: $0["tool"] as? String ?? "",
                     title: $0["title"] as? String ?? "", detail: $0["detail"] as? String ?? "",
                     project: $0["project"] as? String ?? "")
        }
        if newPending != pending { pending = newPending }

        sessions = (r["sessions"] as? [[String: Any]] ?? []).map {
            WorkSession(project: $0["project"] as? String ?? "", working: $0["working"] as? Bool ?? false,
                        since: iso.date(from: $0["since"] as? String ?? "") ?? Date())
        }

        let events = (r["events"] as? [[String: Any]] ?? []).map {
            FeedItem(id: $0["id"] as? Int ?? 0, kind: $0["kind"] as? String ?? "",
                     title: $0["title"] as? String ?? "", body: $0["body"] as? String ?? "",
                     project: $0["project"] as? String ?? "",
                     ts: iso.date(from: $0["ts"] as? String ?? "") ?? Date())
        }
        if !events.isEmpty {
            feed = (events.reversed() + feed).prefix(40).map { $0 }
            // 首次连接拿到的是历史，不震
            if !first, let latest = events.last { buzz(for: latest.kind) }
        }
        seq = r["seq"] as? Int ?? seq

        // Mac 重启后遥控状态会丢，这里补回去
        if keepAlive.isRunning && !remote && !remoteBusy {
            Task { try? await client.setRemote(true) }
        }
    }

    private func buzz(for kind: String) {
        let device = WKInterfaceDevice.current()
        switch kind {
        case "approval":
            device.play(.notification)
            Task { try? await Task.sleep(for: .milliseconds(600)); device.play(.directionUp) }
        case "done": device.play(.success)
        case "idle": device.play(.directionUp)
        case "info": device.play(.click)
        default: break
        }
    }

    // MARK: - 操作

    /// 只往输入框里插入文字，不回车（逗号等符号）
    func insert(_ text: String) {
        Task {
            do { _ = try await client.sendPrompt(text, submit: false); WKInterfaceDevice.current().play(.click) }
            catch { WKInterfaceDevice.current().play(.failure); show("输入失败") }
        }
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            do {
                let target = try await client.sendPrompt(t, submit: autoSubmit)
                WKInterfaceDevice.current().play(.click)
                show("已发送到 \(target)")
            } catch {
                WKInterfaceDevice.current().play(.failure)
                show("发送失败：\(error.localizedDescription)")
            }
        }
    }

    func press(_ key: String, count: Int = 1) {
        Task {
            do { try await client.press(key, count: count) }
            catch { WKInterfaceDevice.current().play(.failure); show("按键失败：\(error.localizedDescription)") }
        }
    }

    // MARK: - 表冠滚轮：累积后每 50ms 发一次，避免请求太密

    private var pendingScroll = 0.0
    private var scrollTask: Task<Void, Never>?
    /// 滚动若干像素，dy > 0 页面往下
    func scroll(pixels: Double) {
        pendingScroll += pixels
        guard scrollTask == nil else { return }
        scrollTask = Task {
            while abs(pendingScroll) >= 1 {
                let dy = Int(pendingScroll.rounded(.towardZero))
                pendingScroll -= Double(dy)
                try? await client.scroll(dy: dy)
                try? await Task.sleep(for: .milliseconds(30))
            }
            scrollTask = nil
        }
    }

    /// 清空输入框：全选 + 删除（按顺序发送）
    func clearInput() {
        Task {
            do {
                try await client.press("cmd+a")
                try await client.press("backspace")
            } catch { WKInterfaceDevice.current().play(.failure); show("清除失败") }
        }
    }

    func decide(_ a: Approval, _ decision: String) {
        pending.removeAll { $0.id == a.id } // 先乐观移除，界面立即响应
        WKInterfaceDevice.current().play(decision == "allow" ? .success : decision == "deny" ? .failure : .click)
        Task {
            do { try await client.decide(a.id, decision) }
            catch { show("没送达：\(error.localizedDescription)") }
        }
    }

    func setRemote(_ on: Bool) {
        remoteBusy = true
        Task {
            defer { remoteBusy = false }
            if on {
                do { try await keepAlive.start() }
                catch { show("后台保活失败：\(error.localizedDescription)") }
            } else {
                keepAlive.stop()
            }
            do {
                try await client.setRemote(on)
                remote = on
                WKInterfaceDevice.current().play(on ? .start : .stop)
                show(on ? "遥控模式：审批会发到手表" : "已回到电脑上审批")
            } catch {
                show("切换失败：\(error.localizedDescription)")
            }
        }
    }

    func show(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == msg { toast = nil }
        }
    }

    var isKeepAliveRunning: Bool { keepAlive.isRunning }
}
