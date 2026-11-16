import ActivityKit
import AppIntents
import Foundation

/// 「不开 App 快速说」的实时活动数据。App 和小组件扩展共用这一个文件。
struct TalkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case recording, processing, ready, sent, failed }
        var phase: Phase
        /// ready：Mac 输入框里现在的文字；failed：失败原因
        var text: String
        var startedAt: Date
    }
}

/// 快捷操作要做的事。意图本身写在这个共用文件里，真正的实现由主 App 在启动时挂进来；
/// 这些意图都由系统放到主 App 进程里执行，小组件扩展里不会真的运行它们。
enum TalkAction { case toggle, cancel, send, clear }

@MainActor
enum TalkBridge {
    static var handler: ((TalkAction) async -> Void)?
}

/// 开始 / 结束说话。录音类意图：系统允许它在后台直接开麦克风，不需要打开 App。
/// 手机侧键、控制中心、锁屏按钮、双击背面（经快捷指令）都调用它。
/// 同时声明成实时活动类意图：这个文件 App 和小组件扩展都编译了，只声明录音类时，
/// 控制中心的按钮会在小组件扩展的进程里执行它，那边没有挂实现，点了就没反应；
/// 实时活动类意图系统一定交给主 App 进程执行。
struct ToggleTalkIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "开始 / 结束说话"
    static var description = IntentDescription("按一下开始说话，再按一下结束，文字进入电脑的输入框。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await TalkBridge.handler?(.toggle)
        return .result()
    }
}

/// 录音中点「取消」：结束录音并删掉这一轮说的字
struct CancelTalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "取消说话"
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await TalkBridge.handler?(.cancel)
        return .result()
    }
}

/// 说完后点「发送」：在 Mac 上按回车
struct SendTalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "发送给 Claude"
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await TalkBridge.handler?(.send)
        return .result()
    }
}

/// 说完后点「清空」：清掉 Mac 输入框
struct ClearTalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "清空输入框"
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await TalkBridge.handler?(.clear)
        return .result()
    }
}
