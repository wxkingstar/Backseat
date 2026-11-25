import AppKit
import Foundation

setlinebuf(stdout)   // 输出重定向到文件时也逐行写出

// 第一次启动自动生成配置、注册 Claude Code hooks，不需要先跑任何脚本
let cfg = Setup.config()
let token = cfg["token"] as? String ?? ""
let port = UInt16(cfg["port"] as? Int ?? 8787)
let hookNote = Setup.installHooks()

// 不在这里弹系统的授权框：设置引导窗口里有「去授权」，按顺序带用户做
let trustedAtLaunch = Keyboard.isTrusted(prompt: false)
if !trustedAtLaunch {
    print("⚠️  还没有「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，打开 Backseat（从终端启动时是那个终端 App）。")
    print("   没有这个权限，手表发来的文字和按键无法注入（审批、提醒不受影响）。")
}

// 可选：指定语音输入法和它的长按快捷键，如 {"voiceIME": {"source": "<输入源 ID>", "holdKey": "fn"}}
// 快捷键也可以在菜单栏里改，改了会写回这里
if let ime = cfg["voiceIME"] as? [String: String], let source = ime["source"] {
    let key = ime["holdKey"] ?? "fn"
    if MicStream.inputSource(source) == nil {
        print("⚠️  config.json 里的 voiceIME.source「\(source)」不是已启用的输入源，语音将使用 Mac 内置识别。")
    } else if Keyboard.holdKeys[key] == nil {
        print("⚠️  voiceIME.holdKey「\(key)」不支持，可选：\(Keyboard.holdKeys.keys.sorted().joined(separator: " / "))")
    }
    MicStream.voiceIME = .init(sourceID: source, holdKey: key)
}

/// 启动失败时弹窗说明再退出：菜单栏 App 没有窗口，直接退出用户只会觉得「打不开」
@MainActor func fail(_ message: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "Backseat 无法启动"
    alert.informativeText = message
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate()
    alert.runModal()
    exit(1)
}
let portNote = "端口 \(port) / \(port + 1) 被占用。可能 Backseat 已经在运行（看屏幕右上角菜单栏），或者别的程序占用了这个端口：在 ~/.backseat/config.json 里把 port 改成别的数字后重新打开。"

let bridge = Bridge(token: token, port: port)
let server: HTTPServer
let inputSocket: InputSocket
do {
    server = try HTTPServer(port: port) { req, res in bridge.handle(req, res) }
    // 手机的高频输入（滚动、鼠标、按键）走常连接，端口 = HTTP 端口 + 1
    inputSocket = try InputSocket(port: port + 1, token: token) { bridge.log($0) }
} catch {
    MainActor.assumeIsolated { fail(portNote) }
}
server.start { DispatchQueue.main.async { MainActor.assumeIsolated { fail(portNote) } } }
inputSocket.start()
SubmitWatch.start { bridge.inputSubmitted() }
bridge.log("backseat 已启动，端口 \(port)。等手表连接…")
if let hookNote { bridge.log(hookNote) }
bridge.log("配对码：\(bridge.pairCode)（第一次使用时，在手表或手机 App 里输入）")
bridge.log("本机地址：\(Bridge.hosts.joined(separator: " / "))")
bridge.log(bridge.voiceNote)
Task { await Transcriber.prepare() }

// Ctrl+C / kill 时走正常退出流程。不能在信号处理函数里直接清理：里面调 CoreAudio 会卡死
let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { exit(0) }
    src.resume()
    return src
}

// 菜单栏应用：不占 Dock。主线程跑 NSApplication，NSWorkspace.frontmostApplication 也能实时更新
/// 再次打开 Backseat（双击、启动台、Spotlight）时没有别的窗口可显示，就弹出设置引导
final class AppDelegate: NSObject, NSApplicationDelegate {
    let onboarding: Onboarding
    init(onboarding: Onboarding) { self.onboarding = onboarding }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { onboarding.show() }
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let onboarding = MainActor.assumeIsolated { Onboarding(bridge: bridge, port: port) }
let delegate = AppDelegate(onboarding: onboarding)
app.delegate = delegate
let statusMenu = StatusMenu(bridge: bridge, port: port) { MainActor.assumeIsolated { onboarding.show() } }
// 第一次启动，或者还没有辅助功能权限：直接弹出设置引导
if !Setup.onboarded || !trustedAtLaunch {
    DispatchQueue.main.async { MainActor.assumeIsolated { onboarding.show() } }
}
app.run()
