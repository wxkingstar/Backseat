import Observation
import SwiftUI
import UIKit

struct Phrase: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var enabled = true

    /// 默认给几条现成的，但都不显示：主屏默认没有快捷短语，要用的自己到设置里打开
    static let defaults = ["继续", "提交代码并上线", "按你的方案做", "跑测试，失败就修"].map { Phrase(text: $0, enabled: false) }

    static func load() -> [Phrase] {
        guard let data = UserDefaults.standard.data(forKey: "phrases"),
              let list = try? JSONDecoder().decode([Phrase].self, from: data) else { return defaults }
        return list
    }

    static func save(_ list: [Phrase]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "phrases")
    }
}

struct PendingApproval: Identifiable, Equatable {
    let id: String
    let tool: String
    let title: String
    let detail: String
    let project: String
}

/// iPhone 端的全部状态：连接、Claude 状态、审批、草稿。和手表共用 BridgeClient。
@MainActor @Observable
final class PhoneStore {
    static let shared = PhoneStore()

    // 连接：最近 30 分钟连通过就乐观显示已连接，后台立即校验
    var connected = PhoneStore.recentlyConnected
    var frontApp = ""
    var remote = false
    var remoteBusy = false

    // Claude 状态
    var workingProject: String?
    var workingSince: Date?
    var lastKind = ""          // done / idle
    var lastProject = ""
    var lastBody = ""

    var pending: [PendingApproval] = []
    var toast: String?
    /// 提示条上「撤回」要做的事；没有就不显示按钮
    var toastUndo: (() -> Void)?
    /// 每次提示一个新 id：同样的文字连着出现时，旧的定时器不会把新的提前收掉
    @ObservationIgnored private var toastID = UUID()

    /// 主屏的快捷短语：可在设置里改文字、隐藏、增删、排序；存在本机
    var phrases: [Phrase] = Phrase.load() {
        didSet { Phrase.save(phrases) }
    }
    /// iPhone Duo 右侧栏的快捷键，从上到下
    var sideKeys: [SideKeyKind] = SideKeyKind.load("sideKeys", fallback: SideKeyKind.defaults) {
        didSet { SideKeyKind.save(sideKeys, "sideKeys") }
    }

    /// 按下一个快捷键（「所有按键」由界面自己处理展开）
    func run(_ k: SideKeyKind) {
        if let t = k.text { insert(t) } else if let key = k.key { press(key) }
    }
    /// Mac 输入框里有没有手机这边说进去 / 打进去、还没发送的内容。有才显示清空和发送键
    var hasDraft = false
    var visiblePhrases: [Phrase] {
        phrases.filter { $0.enabled && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private let client = BridgeClient.shared
    private var seq = -1
    /// Mac 上回车发送的计数，上次看到的值
    private var macSubmits: Int?
    private var loadedOnce = false
    private var pollTask: Task<Void, Never>?
    private let iso = ISO8601DateFormatter()

    private static var recentlyConnected: Bool {
        let t = UserDefaults.standard.double(forKey: "lastConnectedAt")
        return t > 0 && Date().timeIntervalSince1970 - t < 30 * 60
    }

    // MARK: - 轮询

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var failures = 0
            var quick = true
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
                    if failures >= 2 && self.connected {
                        self.connected = false
                        Haptics.error()
                    }
                    let delays = [0.3, 1.0, 2.0]
                    try? await Task.sleep(for: .seconds(failures <= delays.count ? delays[failures - 1] : 3))
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        channel.disconnect()
    }

    func refreshNow() {
        stopPolling()
        startPolling()
    }

    private func apply(_ r: [String: Any]) {
        let first = !loadedOnce
        loadedOnce = true
        connected = true
        channel.connectIfNeeded()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastConnectedAt")
        frontApp = r["frontApp"] as? String ?? ""
        remote = r["remote"] as? Bool ?? false

        let newPending = (r["pending"] as? [[String: Any]] ?? []).map {
            PendingApproval(id: $0["id"] as? String ?? "", tool: $0["tool"] as? String ?? "",
                            title: $0["title"] as? String ?? "", detail: $0["detail"] as? String ?? "",
                            project: $0["project"] as? String ?? "")
        }
        if newPending != pending { pending = newPending }

        let sessions = r["sessions"] as? [[String: Any]] ?? []
        if let w = sessions.first(where: { $0["working"] as? Bool == true }) {
            workingProject = w["project"] as? String
            workingSince = iso.date(from: w["since"] as? String ?? "")
        } else {
            workingProject = nil
            workingSince = nil
        }

        let events = r["events"] as? [[String: Any]] ?? []
        for e in events {
            let kind = e["kind"] as? String ?? ""
            if kind == "done" || kind == "idle" {
                lastKind = kind
                lastProject = e["project"] as? String ?? ""
                lastBody = e["body"] as? String ?? ""
            }
        }
        if !first, let latest = events.last?["kind"] as? String {
            switch latest {
            case "approval": Haptics.warning()
            case "done": Haptics.success()
            case "idle": Haptics.tap()
            default: break
            }
        }
        // 在电脑上按回车发出去了：手机上的清空 / 发送没用了，跟着收起来
        if let n = r["submits"] as? Int {
            if let old = macSubmits, n != old {
                hasDraft = false
                TalkController.shared.sentOnMac()
            }
            macSubmits = n
        }
        seq = r["seq"] as? Int ?? seq
    }

    // MARK: - 操作

    /// 快捷短语：输入并回车
    func send(_ text: String) {
        Task {
            do { _ = try await client.sendPrompt(text, submit: true); Haptics.success(); show("已发送：\(text)") }
            catch { fail(error) }
        }
    }

    /// 在 Mac 的光标处插入文字（逗号等），不回车
    func insert(_ text: String) {
        Task {
            do { _ = try await client.sendPrompt(text, submit: false); hasDraft = true }
            catch { fail(error) }
        }
    }

    func press(_ key: String) {
        if channel.send(#"{"t":"key","key":"\#(key)"}"#) { return }
        Task {
            do { try await client.press(key) }
            catch { fail(error) }
        }
    }

    /// 退格：删 Mac 光标前面的一个字。光标挪到哪，就从哪删
    func backspace() { press("backspace") }

    /// 换行：Mac 输入框里 Shift+回车，不发送
    func newline() { press("shift+enter") }

    func clearInput() {
        Haptics.warning()
        Task {
            // 先把输入框里的字读回来留着，清空后几秒内可以撤回；读不出来的应用（比如终端）就不给撤回
            let saved = (try? await client.inputText()) ?? nil
            do {
                try await client.setInput("", submit: false)
                hasDraft = false
                if let saved, !saved.isEmpty {
                    show("已清空", undo: { [weak self] in self?.restoreInput(saved) })
                } else {
                    show("已清空")
                }
            } catch { fail(error) }
        }
    }

    /// 撤回清空：把原来的字写回 Mac 输入框
    private func restoreInput(_ text: String) {
        Task {
            do { try await client.setInput(text, submit: false); hasDraft = true; Haptics.tap(); show("已撤回") }
            catch { fail(error) }
        }
    }

    /// 发送：在 Mac 上按回车。成功返回 true
    func sendInput() async -> Bool {
        do {
            try await client.press("enter")
            hasDraft = false
            Haptics.success()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // MARK: - 触控板：累积后每 16ms 发一次

    private var pendingScroll = CGVector.zero
    private var scrollTask: Task<Void, Never>?

    private let channel = InputChannel.shared
    private var dragCarry = CGVector.zero

    /// 手指拖动：走常连接立即发给 Mac，内容紧贴手指（不足 1 像素的零头留到下一次）
    func scrollDrag(dx: CGFloat, dy: CGFloat) {
        guard channel.ready else { scroll(dx: dx, dy: dy); return }
        dragCarry.dx += dx
        dragCarry.dy += dy
        let x = Int(dragCarry.dx.rounded(.towardZero)), y = Int(dragCarry.dy.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        dragCarry.dx -= CGFloat(x)
        dragCarry.dy -= CGFloat(y)
        channel.send(#"{"t":"scroll","dx":\#(x),"dy":\#(y)}"#)
    }

    /// 松手：把惯性距离交给 Mac 平滑减速
    func scrollFling(dx: CGFloat, dy: CGFloat) {
        dragCarry = .zero
        if !channel.send(#"{"t":"fling","dx":\#(Int(dx)),"dy":\#(Int(dy))}"#) { scroll(dx: dx, dy: dy) }
    }

    /// HTTP 兜底（常连接没连上时），以及无障碍操作的整段滚动
    func scroll(dx: CGFloat, dy: CGFloat) {
        pendingScroll.dx += dx
        pendingScroll.dy += dy
        guard scrollTask == nil else { return }
        scrollTask = Task {
            while abs(pendingScroll.dx) >= 1 || abs(pendingScroll.dy) >= 1 {
                let x = Int(pendingScroll.dx.rounded(.towardZero)), y = Int(pendingScroll.dy.rounded(.towardZero))
                pendingScroll.dx -= CGFloat(x)
                pendingScroll.dy -= CGFloat(y)
                try? await client.scroll(dx: x, dy: y)
                try? await Task.sleep(for: .milliseconds(16))
            }
            scrollTask = nil
        }
    }

    // MARK: - 鼠标模式：移动累积后每 12ms 发一次，不做平滑，跟手

    private var pendingMouse = CGVector.zero
    private var mouseTask: Task<Void, Never>?

    func moveMouse(dx: CGFloat, dy: CGFloat) {
        pendingMouse.dx += dx
        pendingMouse.dy += dy
        if channel.ready {
            let x = Int(pendingMouse.dx.rounded(.towardZero)), y = Int(pendingMouse.dy.rounded(.towardZero))
            guard x != 0 || y != 0 else { return }
            pendingMouse.dx -= CGFloat(x)
            pendingMouse.dy -= CGFloat(y)
            channel.send(#"{"t":"mouse","dx":\#(x),"dy":\#(y)}"#)
            return
        }
        guard mouseTask == nil else { return }
        mouseTask = Task {
            while abs(pendingMouse.dx) >= 1 || abs(pendingMouse.dy) >= 1 {
                let x = Int(pendingMouse.dx.rounded(.towardZero)), y = Int(pendingMouse.dy.rounded(.towardZero))
                pendingMouse.dx -= CGFloat(x)
                pendingMouse.dy -= CGFloat(y)
                try? await client.moveMouse(dx: x, dy: y)
                try? await Task.sleep(for: .milliseconds(12))
            }
            mouseTask = nil
        }
    }

    /// 打开 Mac 上的调度中心 / 应用程序界面。只走常连接
    func openMacApp(_ name: String) {
        channel.send(#"{"t":"open","app":"\#(name)"}"#)
    }

    @ObservationIgnored private var zoomCarry: CGFloat = 0

    /// 双指捏合：amount > 0 放大。只走常连接
    func zoom(_ amount: CGFloat) {
        zoomCarry += amount
        let n = Int(zoomCarry.rounded(.towardZero))
        guard n != 0 else { return }
        zoomCarry -= CGFloat(n)
        channel.send(#"{"t":"zoom","d":\#(n)}"#)
    }

    /// 按下 / 松开左键（长按后拖拽）。只走常连接：断线时宁可不按，也不能按下后松不开
    func mouseButton(down: Bool) {
        channel.send(down ? #"{"t":"down"}"# : #"{"t":"up"}"#)
    }

    func click(right: Bool, state: Int = 1) {
        if channel.send(#"{"t":"click","right":\#(right),"state":\#(state)}"#) { return }
        Task {
            do { try await client.click(right: right, state: state) }
            catch { fail(error) }
        }
    }

    // MARK: - 审批 / 遥控模式

    func decide(_ a: PendingApproval, _ decision: String) {
        pending.removeAll { $0.id == a.id }
        decision == "allow" ? Haptics.success() : Haptics.tap()
        Task {
            do { try await client.decide(a.id, decision) }
            catch { fail(error) }
        }
    }

    func setRemote(_ on: Bool) {
        remoteBusy = true
        Task {
            defer { remoteBusy = false }
            do {
                try await client.setRemote(on)
                remote = on
                Haptics.tap()
                show(on ? "离开电脑：审批会发到手机" : "已回到电脑上审批")
            } catch { fail(error) }
        }
    }

    // MARK: - 提示

    /// undo 不为空时，提示条上带「撤回」按钮，停留 5 秒
    func show(_ msg: String, undo: (() -> Void)? = nil) {
        let id = UUID()
        toastID = id
        toast = msg
        toastUndo = undo
        Task {
            try? await Task.sleep(for: .seconds(undo == nil ? 2.2 : 5))
            if toastID == id { toast = nil; toastUndo = nil }
        }
    }

    /// 点了提示条上的「撤回」
    func undoToast() {
        let undo = toastUndo
        toast = nil
        toastUndo = nil
        undo?()
    }

    private func fail(_ error: Error) {
        Haptics.error()
        show("失败：\(error.localizedDescription)")
    }
}

/// 震动反馈。生成器常驻并提前 prepare，避免第一次触发有延迟
@MainActor
enum Haptics {
    private static let light: UIImpactFeedbackGenerator = { let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); return g }()
    private static let rigid: UIImpactFeedbackGenerator = { let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare(); return g }()
    private static let notify: UINotificationFeedbackGenerator = { let g = UINotificationFeedbackGenerator(); g.prepare(); return g }()

    static func tap() { light.impactOccurred(intensity: 0.7); light.prepare() }
    static func press() { rigid.impactOccurred(intensity: 0.55); rigid.prepare() }
    static func medium() { rigid.impactOccurred(intensity: 1); rigid.prepare() }
    static func success() { notify.notificationOccurred(.success); notify.prepare() }
    static func warning() { notify.notificationOccurred(.warning); notify.prepare() }
    static func error() { notify.notificationOccurred(.error); notify.prepare() }
}
