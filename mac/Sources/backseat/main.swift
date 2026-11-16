import AppKit
import Foundation

setlinebuf(stdout)   // 输出重定向到文件时也逐行写出

// 第一次启动自动生成配置、注册 Claude Code hooks，不需要先跑任何脚本
let cfg = Setup.config()
let token = cfg["token"] as? String ?? ""
let port = UInt16(cfg["port"] as? Int ?? 8787)
let hookNote = Setup.installHooks()

if !Keyboard.isTrusted(prompt: true) {
    print("⚠️  还没有「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，打开 Backseat（从终端启动时是那个终端 App）。")
    print("   没有这个权限，手表发来的文字和按键无法注入（审批、提醒不受影响）。")
}

// 可选：指定语音输入法，如 {"voiceIME": {"source": "<输入源 ID>", "holdKey": "rightCommand"}}
if let ime = cfg["voiceIME"] as? [String: String], let source = ime["source"] {
    let key = ime["holdKey"] ?? "rightCommand"
    if MicStream.inputSource(source) == nil {
        print("⚠️  config.json 里的 voiceIME.source「\(source)」不是已启用的输入源，语音将使用 Mac 内置识别。")
    } else if Keyboard.holdKeys[key] == nil {
        print("⚠️  voiceIME.holdKey「\(key)」不支持，可选：\(Keyboard.holdKeys.keys.sorted().joined(separator: " / "))")
    }
    MicStream.voiceIME = .init(sourceID: source, holdKey: key)
}

let bridge = Bridge(token: token, port: port)
let server = try HTTPServer(port: port) { req, res in bridge.handle(req, res) }
server.start()
// 手机的高频输入（滚动、鼠标、按键）走常连接，端口 = HTTP 端口 + 1
let inputSocket = try InputSocket(port: port + 1, token: token) { bridge.log($0) }
inputSocket.start()
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
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusMenu = StatusMenu(bridge: bridge, port: port)
app.run()
