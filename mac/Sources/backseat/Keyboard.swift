import AppKit
import ApplicationServices

/// 向当前前台 App 注入按键 / 文本。需要「辅助功能」权限。
enum Keyboard {
    static let keyCodes: [String: CGKeyCode] = [
        "enter": 36, "esc": 53, "tab": 48, "space": 49, "backspace": 51,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "1": 18, "2": 19, "3": 20, "4": 21, "y": 16, "n": 45, "a": 0, "c": 8, "v": 9, "[": 33, "]": 30, "d": 2, "f11": 103,
    ]

    static func isTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var frontAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
    }

    /// key 形如 "enter" / "shift+tab" / "ctrl+c"
    @discardableResult
    static func press(_ combo: String) -> Bool {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return false }
        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "shift": flags.insert(.maskShift)
            case "ctrl": flags.insert(.maskControl)
            case "cmd": flags.insert(.maskCommand)
            case "alt", "opt": flags.insert(.maskAlternate)
            default: break
            }
        }
        post(code, flags: flags)
        return true
    }

    /// 通过剪贴板粘贴文本（支持中文、多行），可选回车发送，之后恢复原剪贴板。
    static func paste(_ text: String, submit: Bool) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        post(9, flags: .maskCommand) // cmd+v
        if submit {
            Thread.sleep(forTimeInterval: 0.35)
            post(36, flags: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let saved else { return }
            // 只在剪贴板仍是我们写入的内容时恢复，避免覆盖用户新复制的东西
            if pb.string(forType: .string) == text {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    private static var scrollPoint: (point: CGPoint, at: Date)?
    private static var pending = CGVector.zero   // 还没滚完的距离
    private static var carry = CGVector.zero     // 不足 1 像素的零头，留到下一帧
    private static var scrollTimer: Timer?
    private static var gestureActive = false

    /// 平滑滚动前台窗口上半部分的内容（对话区），而不是鼠标或光标所在的输入框。
    /// dy > 0 页面往下滚，dx > 0 页面往右滚。两点保证丝滑：
    /// 1. 以触控板的「连续滚动」事件发出（带 began/changed/ended 阶段）。普通滚轮事件会被浏览器内核
    ///    （Claude 桌面版是 Electron）各自再做一次平滑动画，大量小事件叠加反而一顿一顿。
    /// 2. 120Hz 匀速消化收到的距离（时间常数约 90ms），亚像素零头累积，不丢不跳。
    static func scroll(dx: Int = 0, dy: Int) {
        pending.dx += CGFloat(dx)
        pending.dy += CGFloat(dy)
        guard scrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { t in
            let ex = pending.dx * 0.09 + carry.dx, ey = pending.dy * 0.09 + carry.dy
            let sx = ex.rounded(.towardZero), sy = ey.rounded(.towardZero)
            carry = CGVector(dx: ex - sx, dy: ey - sy)
            pending.dx -= pending.dx * 0.09
            pending.dy -= pending.dy * 0.09
            if sx != 0 || sy != 0 {
                postScroll(dx: Int(sx), dy: Int(sy), phase: gestureActive ? 2 : 1)
                gestureActive = true
            }
            if abs(pending.dx) < 0.5, abs(pending.dy) < 0.5, abs(carry.dx) < 1, abs(carry.dy) < 1 {
                pending = .zero
                carry = .zero
                if gestureActive { postScroll(dx: 0, dy: 0, phase: 4) }   // ended
                gestureActive = false
                t.invalidate()
                scrollTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    /// 手指拖动时用：不做平滑，立即滚这么多，内容紧贴手指。松手后的惯性再交给 scroll() 平滑减速
    static func scrollDirect(dx: Int, dy: Int) {
        // 手指重新按上来：打断还没滚完的惯性
        pending = .zero
        carry = .zero
        guard dx != 0 || dy != 0 else { return }
        postScroll(dx: dx, dy: dy, phase: gestureActive ? 2 : 1)
        gestureActive = true
    }

    /// 事件带上目标位置，系统按这个位置把滚轮事件派给对应的视图，鼠标指针本身不动。
    /// phase：1 began / 2 changed / 4 ended（kCGScrollPhase）
    private static func postScroll(dx: Int, dy: Int, phase: Int64) {
        // 和 Mac 触控板一样，滚动作用在指针所在的位置。
        // 例外：最近 10 秒没有用手机移动过指针，说明用户只是想翻对话，这时自动对准输入框上方的对话区
        if Date().timeIntervalSince(lastPointerMove) < 10 {
            let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                             wheelCount: 2, wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0)
            ev?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            ev?.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
            ev?.flags = []
            emit(ev)
            return
        }
        // 目标点 3 秒内复用（查一次输入框位置要几十毫秒）
        if scrollPoint == nil || Date().timeIntervalSince(scrollPoint!.at) > 3 {
            scrollPoint = Focus.scrollTarget().map { ($0, Date()) }
            if let p = scrollPoint?.point, let w = Focus.frontWindowFrame() {
                print("滚动目标：窗口内 \(Int((p.x - w.minX) / w.width * 100))% 宽、\(Int((p.y - w.minY) / w.height * 100))% 高（\(frontAppName)）")
                fflush(stdout)
            }
        }
        // 滚轮事件是按鼠标指针所在位置派发的。以前给每个事件单独指定位置，指针会在原位置和目标点之间来回跳（闪烁）。
        // 现在：手势开始时把指针移到目标点一次，中间的事件不再带位置；停止滚动 0.8 秒后再把指针放回原处，
        // 连续滑几下时指针一直停在对话区，不会来回跳。
        restoreWork?.cancel()
        if let p = scrollPoint?.point, let cur = CGEvent(source: nil)?.location, hypot(cur.x - p.x, cur.y - p.y) > 4 {
            if cursorBefore == nil { cursorBefore = cur }
            CGWarpMouseCursorPosition(p)
        }
        let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                         wheelCount: 2, wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0)
        ev?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev?.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)   // kCGScrollWheelEventScrollPhase
        ev?.flags = []
        emit(ev)
        if phase == 4 {
            let work = DispatchWorkItem {
                guard let back = cursorBefore else { return }
                cursorBefore = nil
                CGWarpMouseCursorPosition(back)
            }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }
    private static var cursorBefore: CGPoint?
    private static var restoreWork: DispatchWorkItem?

    // MARK: - 鼠标（手机触控板的「鼠标模式」）

    /// 所有显示器拼起来的范围（全局坐标，左上角原点），鼠标不会被移出屏幕
    private static var desktopBounds: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// 相对移动鼠标指针
    static func moveMouse(dx: Int, dy: Int) {
        let cur = pointer()
        let b = desktopBounds
        let p = CGPoint(x: min(max(cur.x + CGFloat(dx), b.minX), b.maxX - 1),
                        y: min(max(cur.y + CGFloat(dy), b.minY), b.maxY - 1))
        // 按住拖拽时发 dragged 事件，才能选中文字、拖动窗口
        let ev = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                         mouseType: leftDown ? .leftMouseDragged : .mouseMoved,
                         mouseCursorPosition: p, mouseButton: .left)
        ev?.flags = []
        emit(ev)
        CursorOverlay.show(at: p)
        phonePoint = p
        lastPointerMove = Date()
        // 指针已经由用户接管，不要再被「滚动结束后放回原位」拽走
        restoreWork?.cancel()
        cursorBefore = nil
    }

    /// 捏合缩放：发带 Control 的滚轮事件，作用在指针所在位置。
    /// 浏览器内核的应用（Claude、Chrome、Figma、VS Code 等）把它当作触控板捏合来处理。amount > 0 放大
    static func zoom(_ amount: Int) {
        guard amount != 0 else { return }
        let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                         wheelCount: 1, wheel1: Int32(clamping: amount), wheel2: 0, wheel3: 0)
        ev?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev?.flags = .maskControl
        emit(ev)
    }

    private static var lastPointerMove = Date.distantPast
    /// 手机最后一次把指针放到的位置
    private static var phonePoint: CGPoint?

    /// 手机操作应该作用的位置。
    /// 手机刚操控过（8 秒内，也就是绿色指针还显示着）就用手机放的位置，而不是系统当前的指针位置：
    /// 远程桌面连着的时候，对端的鼠标一动，这台 Mac 的指针就被拽到对端鼠标的位置，
    /// 这时按系统指针位置去点，会点在对端鼠标那里，而不是手机上看到的绿色指针那里。
    private static func pointer() -> CGPoint {
        if let p = phonePoint, Date().timeIntervalSince(lastPointerMove) < 8 { return p }
        return CGEvent(source: nil)?.location ?? .zero
    }
    private static var leftDown = false

    /// 按下 / 松开左键（长按后拖拽用）
    static func mouseButton(down: Bool) {
        guard down != leftDown else { return }
        leftDown = down
        let p = pointer()
        let ev = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                         mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        ev?.flags = []
        emit(ev)
    }

    /// 在当前指针位置点一下。state = 2 表示这是双击的第二下（手机上连点两下时发）
    static func click(right: Bool, state: Int) {
        let p = pointer()
        CursorOverlay.show(at: p)
        // 点击也算手机在操控，接着连点、双击都留在同一个位置
        phonePoint = p
        lastPointerMove = Date()
        let src = CGEventSource(stateID: .hidSystemState)
        let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for t in [down, up] {
            let ev = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p,
                             mouseButton: right ? .right : .left)
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, min(state, 3))))
            // 明确不带任何修饰键。不清掉的话，鼠标事件会沿用系统当前的修饰键状态：
            // 刚发过带 Control 的事件（四指切换桌面、捏合缩放）后，单击会变成 Control+单击，也就是右键
            ev?.flags = []
            emit(ev)
        }
    }

    /// 语音输入法「长按说话」可用的快捷键：键码、修饰键标志、区分左右的设备标志（NX_DEVICE*KEYMASK）
    static let holdKeys: [String: (code: CGKeyCode, flag: CGEventFlags, device: UInt64)] = [
        "rightCommand": (54, .maskCommand, 0x10),
        "rightOption": (61, .maskAlternate, 0x40),
        "rightControl": (62, .maskControl, 0x2000),
        "rightShift": (60, .maskShift, 0x04),
        "fn": (63, .maskSecondaryFn, 0),
    ]

    /// 按下 / 松开语音输入法的长按快捷键（豆包默认是右 ⌘）。只在主线程调用
    static func hold(_ key: String, down: Bool) {
        guard let k = holdKeys[key] else { return }
        if down {
            blockedReleases = 0
            installHoldGuard()
            holding = (k.code, k.flag)
        } else {
            holding = nil
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let ev = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: down)
        ev?.type = .flagsChanged
        ev?.flags = down ? CGEventFlags(rawValue: k.flag.rawValue | k.device) : []
        ev?.setIntegerValueField(.eventSourceUserData, value: ownEventMark)
        ev?.post(tap: CGEventTapLocation.cghidEventTap)
    }

    /// 发出一个鼠标 / 键盘事件。
    /// 事件上带 RustDesk 自己发事件时用的标记（它的输入库 enigo 的 ENIGO_INPUT_EXTRA_VALUE）：
    /// RustDesk 开着隐私模式 / 禁止本地输入时，会在最底层拦掉所有不带这个标记的鼠标点击和按键
    /// （它把这些当成「本地有人在动这台电脑」）。不带标记的话，远程连着的时候手机的点击和按键全部石沉大海。
    /// RustDesk 没在运行时这个标记没有任何作用。
    private static func emit(_ ev: CGEvent?) {
        ev?.setIntegerValueField(.eventSourceUserData, value: 100)
        ev?.post(tap: .cghidEventTap)
    }

    // MARK: - 按住期间不让别人把快捷键松开
    //
    // 我们「按住」右 ⌘ 只是发了一个按下事件，系统里并没有一只真的手按着。
    // 远程桌面（RustDesk 等）每收到一次对端的鼠标 / 键盘事件，都会把本机的修饰键对齐成对端的状态：
    // 对端没按 ⌘，它就替我们发一个 ⌘ 松开，输入法的语音条刚出来一秒就收了。
    // 所以按住期间拦掉不是我们自己发的「松开」。

    /// 正在按住的键；nil = 没在按
    private static var holding: (code: CGKeyCode, flag: CGEventFlags)?
    /// 这一轮拦下了几次外部的松开（记进日志，方便确认原因）
    private(set) static var blockedReleases = 0
    /// 我们自己发的事件带这个标记，拦截时放行
    private static let ownEventMark: Int64 = 0x0BAC_5EA7
    private static var holdGuard: CFMachPort?
    /// 每种修饰键的左右两个键码：⌘、⌥、⌃、⇧
    private static let modifierKeys: [Set<CGKeyCode>] = [[54, 55], [58, 61], [59, 62], [56, 60]]

    private static func installHoldGuard() {
        guard holdGuard == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            // 系统嫌回调慢或用户输入时会把拦截停掉，重新打开
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = Keyboard.holdGuard { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let h = Keyboard.holding,
                  event.getIntegerValueField(.eventSourceUserData) != Keyboard.ownEventMark
            else { return Unmanaged.passUnretained(event) }
            // 同一种修饰键的左右两个键都要拦：对方松开时是左右一起发的，
            // 只拦右 ⌘、放过左 ⌘ 的松开，输入法照样会当成松手
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let sameModifier = Keyboard.modifierKeys.first { $0.contains(h.code) }?.contains(code) ?? (code == h.code)
            let releases = (type == .flagsChanged && !event.flags.contains(h.flag)) || (type == .keyUp && sameModifier)
            guard releases else { return Unmanaged.passUnretained(event) }
            Keyboard.blockedReleases += 1
            return nil
        }, userInfo: nil) else { return }
        holdGuard = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func post(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            ev?.flags = flags
            emit(ev)
            usleep(8_000)
        }
    }
}
