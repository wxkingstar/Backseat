import AppKit
import ApplicationServices

/// 记住最后一次在用的输入框；光标丢了（点到别处、切到别的 App）时，输入前把焦点拉回去。
/// 需要「辅助功能」权限。Electron 应用（如 Claude 桌面版）要先打开 AXManualAccessibility 才会暴露输入框。
enum Focus {
    private static var remembered: (pid: pid_t, element: AXUIElement)?
    private static var enabledPIDs = Set<pid_t>()

    /// 只认真正的文本输入控件。网页区域（AXWebArea）、分组（AXGroup）的值也可能「可写」，不能算输入框
    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// 输入前调用：光标在输入框就记住它；不在就把光标放回输入框。返回日志说明。
    /// 找输入框的顺序：上次记住的（仍然有效）→ 在目标窗口里搜索最靠下的文本框（聊天输入框都在底部）。
    /// 最近一次确认「光标在输入框」的时间。连续按键（比如按住退格）时不必每次都查一遍，查一次要几十毫秒
    private static var lastOK: (pid: pid_t, at: Date)?

    // MARK: - 目标应用：空 = 跟随 Mac 的前台应用；设了就总是输入到这个应用（不在前台会先切过去）

    private static let targetFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".backseat/target")
    static var targetBundleID: String = (try? String(contentsOf: targetFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "" {
        didSet {
            try? targetBundleID.write(to: targetFile, atomically: true, encoding: .utf8)
            lastOK = nil
            remembered = nil
        }
    }

    private static var targetApp: NSRunningApplication? {
        targetBundleID.isEmpty ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).first
    }

    /// 正在运行的普通应用（名字 + bundle id），按名字排序
    static func runningApps() -> [[String: String]] {
        var list: [[String: String]] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier else { continue }
            list.append(["name": app.localizedName ?? bundle, "bundle": bundle])
        }
        return list.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
    }

    /// 设了目标应用且它不在前台：切过去
    static func activateTarget() {
        guard let t = targetApp, !t.isActive else { return }
        t.activate()
        Thread.sleep(forTimeInterval: 0.25)
        lastOK = nil
    }

    @discardableResult
    static func ensureInput() -> String {
        activateTarget()
        if let ok = lastOK, Date().timeIntervalSince(ok.at) < 1.5,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ok.pid {
            return "光标在输入框"
        }
        let cur = current()
        let curRole = cur.map { role($0.1) } ?? "无"
        if let (pid, el) = cur, editableRoles.contains(curRole) {
            remembered = (pid, el)
            lastOK = (pid, Date())
            return "光标在输入框"
        }

        // 目标 App：上次用过的输入框所在 App；没有就用当前前台 App
        let pid = targetApp?.processIdentifier ?? remembered?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard let app = NSRunningApplication(processIdentifier: pid) else { return "找不到目标 App" }
        if !app.isActive {
            app.activate()
            Thread.sleep(forTimeInterval: 0.2)
        }

        var tried: [AXUIElement] = []
        if let r = remembered, r.pid == pid { tried.append(r.element) }
        if let found = searchInput(pid: pid) { tried.append(found) }
        for el in tried {
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.08)
            if let (_, now) = current(), editableRoles.contains(role(now)) {
                remembered = (pid, now)
                lastOK = (pid, Date())
                return "已把光标拉回输入框（原来在 \(curRole)）"
            }
        }
        remembered = nil
        return "拉回失败（原来在 \(curRole)，找到 \(tried.count) 个候选）"
    }

    /// 在 App 的当前窗口里找最靠下的文本输入框（广度优先，限制节点数，避免网页太大卡住）
    private static func searchInput(pid: pid_t) -> AXUIElement? {
        let axApp = axApplication(pid)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &w) == .success,
              let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var queue: [AXUIElement] = [w as! AXUIElement]
        var best: (el: AXUIElement, y: CGFloat)?
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let el = queue.removeFirst()
            visited += 1
            if editableRoles.contains(role(el)) {
                let y = position(el)?.y ?? 0
                if best == nil || y > best!.y { best = (el, y) }
                continue
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                queue.append(contentsOf: arr)
            }
        }
        return best?.el
    }

    private static func position(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        var p = CGPoint.zero
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success, let v,
              AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    /// 当前聚焦输入框里的全部文字；焦点不在输入框或读不到时返回 nil
    static func focusedText() -> String? {
        guard let (_, el) = current(), editableRoles.contains(role(el)) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// 滚动应该落在哪：输入框正上方的对话区（聊天类 App 的输出内容都在输入框上面）。
    /// 不能用窗口正中：Claude 右边开着设计稿 / 文件面板时，正中会落到右侧面板里
    static func scrollTarget() -> CGPoint? {
        activateTarget()
        guard let win = frontWindowFrame() else { return nil }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        var input: CGRect?
        if let r = remembered, r.pid == pid { input = frame(r.element) }
        if input == nil, let el = searchInput(pid: pid) { input = frame(el) }
        if let f = input, f.width > 40, win.contains(CGPoint(x: f.midX, y: f.midY)) {
            return CGPoint(x: f.midX, y: max(win.minY + 90, f.minY - 220))
        }
        // 找不到输入框：退回窗口偏左上的位置
        return CGPoint(x: win.minX + win.width * 0.35, y: win.minY + win.height * 0.38)
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el) else { return nil }
        var v: CFTypeRef?
        var s = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success, let v,
              AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// 前台 App 当前窗口在屏幕上的位置（全局坐标，左上角原点），拿不到返回 nil
    static func frontWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = axApplication(app.processIdentifier)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &w) == .success,
              let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let win = w as! AXUIElement
        var pos: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &size)
        var p = CGPoint.zero, s = CGSize.zero
        guard let pos, let size,
              AXValueGetValue(pos as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func axApplication(_ pid: pid_t) -> AXUIElement {
        let axApp = AXUIElementCreateApplication(pid)
        if !enabledPIDs.contains(pid) {
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(pid)
        }
        return axApp
    }

    private static func current() -> (pid_t, AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApplication(pid), kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let f, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (pid, f as! AXUIElement)
    }

    private static func role(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        return r as? String ?? "未知"
    }
}
