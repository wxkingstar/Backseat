import AppKit
import ServiceManagement

/// 菜单栏图标：看配对码、本机地址、权限状态，设置登录时启动，退出。
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let bridge: Bridge
    private let port: UInt16

    init(bridge: Bridge, port: UInt16) {
        self.bridge = bridge
        self.port = port
        super.init()
        item.button?.image = NSImage(systemSymbolName: "applewatch.radiowaves.left.and.right",
                                     accessibilityDescription: "Backseat")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// 每次点开时重建，配对码和权限状态都是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        func action(_ title: String, _ selector: Selector, on: Bool = false) {
            let i = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
        }

        info("Backseat 运行中 · 端口 \(port)")
        let code = bridge.pairCode
        info("配对码：\(code.prefix(3)) \(code.suffix(3))")
        for host in Bridge.hosts { info("本机地址：\(host)") }
        info("语音：\(MicStream.voiceIME == nil ? "Mac 内置识别" : MicStream.imeName)")
        menu.addItem(.separator())
        if Keyboard.isTrusted(prompt: false) {
            info("辅助功能权限：已授权")
        } else {
            action("辅助功能权限：未授权，点此打开设置…", #selector(openAccessibility))
        }
        // 只有打包成 .app 运行时才能注册登录项
        if Bundle.main.bundleIdentifier != nil {
            action("登录时启动", #selector(toggleLoginItem), on: SMAppService.mainApp.status == .enabled)
        }
        menu.addItem(.separator())
        action("退出", #selector(quit))
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
