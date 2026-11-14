import SwiftUI

@main
struct BackseatApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var store = PhoneStore.shared

    init() {
        // 快捷操作（侧键、控制中心、锁屏卡片上的按钮）由系统在后台唤起 App 后调用到这里
        TalkBridge.handler = { action in await TalkController.shared.handle(action) }
    }

    var body: some Scene {
        WindowGroup {
            Gate()
                .environment(store)
                .preferredColorScheme(.dark)
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

enum P {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.047)          // #0B0B0C
    static let card = Color(red: 0.11, green: 0.11, blue: 0.118)          // #1C1C1E
    static let key = Color(red: 0.149, green: 0.149, blue: 0.165)         // #26262A
    static let line = Color(red: 0.165, green: 0.165, blue: 0.184)        // #2A2A2F
    static let pad = Color(red: 0.075, green: 0.075, blue: 0.082)         // #131315
    static let text2 = Color(red: 0.604, green: 0.604, blue: 0.627)       // #9A9AA0
    static let text3 = Color(red: 0.557, green: 0.557, blue: 0.58)        // #8E8E94
    static let accent = Color(red: 0.878, green: 0.541, blue: 0.427)      // #E08A6D 文字/图标
    static let accentFill = Color(red: 0.784, green: 0.376, blue: 0.247)  // #C8603F 白字底色
    static let ok = Color(red: 0.204, green: 0.659, blue: 0.369)          // #34A85E
    static let okText = Color(red: 0.298, green: 0.824, blue: 0.478)      // #4CD27A
    static let dangerBg = Color(red: 0.227, green: 0.145, blue: 0.137)    // #3A2523
    static let dangerText = Color(red: 1, green: 0.541, blue: 0.502)      // #FF8A80
}
