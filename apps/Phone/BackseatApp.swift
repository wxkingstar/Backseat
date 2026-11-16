import SwiftUI

@main
struct BackseatApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var store = PhoneStore.shared
    @AppStorage("appearance") private var appearance = "system"

    init() {
        // 快捷操作（侧键、控制中心、锁屏卡片上的按钮）由系统在后台唤起 App 后调用到这里
        TalkBridge.handler = { action in await TalkController.shared.handle(action) }
        // 把配对信息同步给手表
        DeviceSync.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Gate()
                .environment(store)
                // 外观：默认跟随系统，设置里可以固定成浅色或深色
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .task {
                    // 自测：往收件箱存 2 秒静音，确认存储和识别流程能跑完，结果发到 Mac 日志
                    if ProcessInfo.processInfo.arguments.contains("-inboxTest") {
                        try? await Task.sleep(for: .seconds(3))
                        Inbox.shared.add(pcm: Data(count: 64_000))
                        try? await Task.sleep(for: .seconds(8))
                        let item = Inbox.shared.items.first
                        _ = try? await BridgeClient.shared.call("POST", "/api/log", body: [
                            "text": "收件箱自测：\(Inbox.shared.items.count) 条，第一条文字「\(item?.text ?? "无")」，待识别=\(item?.audio != nil)"])
                        if let item { Inbox.shared.remove(item.id) }
                    }
                    // 自测：模拟按一下快捷操作开始说话，5 秒后再按一下结束
                    if ProcessInfo.processInfo.arguments.contains("-quickTalkTest") {
                        try? await Task.sleep(for: .seconds(2))
                        await TalkController.shared.handle(.toggle)
                        try? await Task.sleep(for: .seconds(5))
                        await TalkController.shared.handle(.toggle)
                    }
                    if ProcessInfo.processInfo.arguments.contains("-micTest") {
                        try? await Task.sleep(for: .seconds(2))
                        await MicTest.run()
                    }
                }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: store.refreshNow()
            case .background: store.stopPolling()
            default: break
            }
        }
    }
}

/// 一个颜色的浅色 / 深色两个取值，跟着当前外观自动切换
private func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(UIColor { t in
        let c = t.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}

enum P {
    //                         浅色                    深色
    static let bg = dyn((0.949, 0.949, 0.969), (0.043, 0.043, 0.047))          // 页面底色
    static let card = dyn((1, 1, 1), (0.11, 0.11, 0.118))                      // 卡片
    static let key = dyn((0.886, 0.886, 0.91), (0.149, 0.149, 0.165))          // 按键
    static let raised = dyn((0.91, 0.91, 0.93), (0.17, 0.17, 0.17))            // 卡片上面再浮起一层的按键
    static let raisedLine = dyn((0.80, 0.80, 0.82), (0.24, 0.24, 0.24))
    static let sunken = dyn((0.953, 0.953, 0.965), (0.055, 0.055, 0.055))      // 卡片里凹下去的区域
    static let line = dyn((0.84, 0.84, 0.86), (0.165, 0.165, 0.184))
    static let pad = dyn((0.985, 0.985, 0.992), (0.075, 0.075, 0.082))         // 触控板
    static let padLine = dyn((0.86, 0.86, 0.88), (0.13, 0.13, 0.13))
    static let padDot = dyn((0.84, 0.84, 0.86), (0.15, 0.15, 0.15))
    static let text = dyn((0.11, 0.11, 0.118), (1, 1, 1))                      // 主要文字 / 图标
    static let textSoft = dyn((0.30, 0.30, 0.32), (0.79, 0.79, 0.79))
    static let text2 = dyn((0.40, 0.40, 0.42), (0.604, 0.604, 0.627))
    static let text3 = dyn((0.45, 0.45, 0.47), (0.557, 0.557, 0.58))
    static let accent = dyn((0.722, 0.314, 0.184), (0.878, 0.541, 0.427))      // 文字 / 图标用的强调色
    static let accentFill = Color(red: 0.784, green: 0.376, blue: 0.247)       // #C8603F 白字底色
    static let ok = Color(red: 0.204, green: 0.659, blue: 0.369)               // #34A85E 白字底色
    static let okText = dyn((0.11, 0.49, 0.25), (0.298, 0.824, 0.478))
    static let warn = dyn((0.80, 0.55, 0.05), (0.96, 0.76, 0.28))
    static let warnText = dyn((0.56, 0.38, 0.02), (0.96, 0.84, 0.54))
    static let dangerBg = dyn((0.988, 0.886, 0.875), (0.227, 0.145, 0.137))
    static let dangerText = dyn((0.76, 0.18, 0.15), (1, 0.541, 0.502))
}
