import AppKit
import ServiceManagement
import SwiftUI

/// 菜单栏图标：看配对码、本机地址、权限状态，设置登录时启动，退出。
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let bridge: Bridge
    private let port: UInt16
    private let showOnboarding: () -> Void

    /// Backseat 的标志：尖括号里一支麦克风。模板图，颜色跟着菜单栏 / 前景色走。
    /// 坐标按 App 图标的 150×150 画布写，这里只取图形所在的那一块（x 17…133，y 39…108）
    static func logo(height: CGFloat) -> NSImage {
        let k = height / 69
        let image = NSImage(size: NSSize(width: 116 * k, height: height), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: k)
            t.translateX(by: -17, yBy: -39)
            t.concat()
            NSColor.black.set()
            let lines = NSBezierPath()
            lines.lineWidth = 10
            lines.lineCapStyle = .round
            lines.lineJoinStyle = .round
            lines.move(to: NSPoint(x: 42, y: 55)); lines.line(to: NSPoint(x: 22, y: 75)); lines.line(to: NSPoint(x: 42, y: 95))
            lines.move(to: NSPoint(x: 108, y: 55)); lines.line(to: NSPoint(x: 128, y: 75)); lines.line(to: NSPoint(x: 108, y: 95))
            // 麦克风下面的托弧（画布是翻转的，y 向下）
            lines.move(to: NSPoint(x: 58, y: 74))
            lines.appendArc(withCenter: NSPoint(x: 75, y: 74), radius: 17, startAngle: 180, endAngle: 0, clockwise: true)
            lines.move(to: NSPoint(x: 75, y: 91)); lines.line(to: NSPoint(x: 75, y: 103))
            lines.stroke()
            NSBezierPath(roundedRect: NSRect(x: 66, y: 44, width: 18, height: 38), xRadius: 9, yRadius: 9).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    init(bridge: Bridge, port: UInt16, showOnboarding: @escaping () -> Void) {
        self.bridge = bridge
        self.port = port
        self.showOnboarding = showOnboarding
        super.init()
        // 和手机、手表 App 图标同一个图形：尖括号里一支麦克风
        item.button?.image = Self.logo(height: 15)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// 每次点开时重建，配对码和权限状态都是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func action(_ title: String, _ symbol: String, _ selector: Selector, on: Bool = false) {
            let i = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        // 信息部分用自定义视图：系统菜单里没有动作的条目会被画成灰色，看起来像没生效
        let trusted = Keyboard.isTrusted(prompt: false)
        let header = NSHostingView(rootView: MenuHeader(
            code: bridge.pairCode,
            hosts: Bridge.hosts,
            port: port,
            voice: MicStream.voiceIME == nil ? "Mac 内置识别" : MicStream.imeName,
            trusted: trusted))
        header.frame = NSRect(origin: .zero, size: header.fittingSize)
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())

        action("拷贝配对码", "number", #selector(copyCode))
        if !Bridge.hosts.isEmpty { action("拷贝本机地址", "doc.on.doc", #selector(copyHost)) }
        if !trusted { action("打开辅助功能设置…", "hand.raised", #selector(openAccessibility)) }
        // 语音快捷键要和语音输入法里设的「长按说话」一致，这里替你按住它
        if let ime = MicStream.voiceIME {
            let keys = NSMenu()
            for (key, title) in Self.holdKeyTitles {
                let i = keys.addItem(withTitle: title, action: #selector(pickHoldKey(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = key
                i.state = key == ime.holdKey ? .on : .off
            }
            let current = Self.holdKeyTitles.first { $0.key == ime.holdKey }?.title ?? ime.holdKey
            let parent = menu.addItem(withTitle: "语音快捷键：\(current)", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            parent.submenu = keys
        }
        // 只有打包成 .app 运行时才能注册登录项
        if Bundle.main.bundleIdentifier != nil {
            action("登录时启动", "power", #selector(toggleLoginItem), on: SMAppService.mainApp.status == .enabled)
        }
        action("设置向导…", "checklist", #selector(openOnboarding))
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Backseat", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyCode() { copy(bridge.pairCode) }
    @objc private func copyHost() { if let h = Bridge.hosts.first { copy(h) } }

    /// 菜单里显示的顺序和名字；Fn 是豆包的默认设置
    private static let holdKeyTitles: [(key: String, title: String)] = [
        ("fn", "Fn"), ("rightCommand", "右 ⌘"), ("rightOption", "右 ⌥"), ("rightControl", "右 ⌃"), ("rightShift", "右 ⇧"),
    ]

    @objc private func pickHoldKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let ime = MicStream.voiceIME else { return }
        MicStream.voiceIME = .init(sourceID: ime.sourceID, holdKey: key)
        Setup.saveVoiceIME(source: ime.sourceID, holdKey: key)
    }

    @objc private func openOnboarding() { showOnboarding() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// 菜单顶部的状态卡：正常的文字颜色，配对码放大
private struct MenuHeader: View {
    let code: String
    let hosts: [String]
    let port: UInt16
    let voice: String
    let trusted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: StatusMenu.logo(height: 11)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.15), Color(red: 0.85, green: 0.25, blue: 0.35)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                Text("Backseat").font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("运行中").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("配对码").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 34, height: 40)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
                    }
                }
                Text("第一次使用时，在手机或手表的 Backseat 里输入").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                row("本机地址", hosts.isEmpty ? "没有网络" : hosts.joined(separator: "\n"))
                row("端口", "\(port)")
                row("语音识别", voice)
                row("辅助功能", trusted ? "已授权" : "未授权，文字和按键无法输入", warn: !trusted)
                // 不是打包成 .app 运行（swift run）时没有版本号
                row("版本", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(warn ? Color.orange : Color.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
